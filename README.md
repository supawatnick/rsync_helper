# rsync-helper

A Kubernetes **data migration / continuous replication helper** for moving PVC
data between storage backends (e.g. iSCSI → NFS, block → file) **without
downtime of the writing application**.

It runs `rsync` in a loop between a **source** and a **destination** volume,
verifies integrity with **MD5**, and writes a full history log
(BEFORE → CHANGE SUMMARY → AFTER → MD5) to a separate log volume.

> ภาษาไทย ไม่ได้แปลเป็น Van คือ README นี้เป็น bilingual — sections จะมีทั้ง EN และ TH
> (This README is bilingual: each section has an English part and a Thai summary.)

---

## Why this exists / ที่มา

| | |
|---|---|
| EN | Kubernetes `rsync` does not protect the host SSH; here we use a **golden image** that ships `rsync` + `coreutils` + `tzdata` pre-installed. The pod reads data from a `src` PVC and writes to a `dst` PVC in a 300s loop, logging an iteration history (BEFORE / CHANGE / AFTER / MD5) to a third PVC. |
| TH | โครงการนี้ใช้ **golden image** ที่ฝัง rsync + coreutils + tzdata ไว้แล้ว → pod เริ่มทำงานทันที **โดยไม่ต้องออก internet เพื่อติดตั้ง package** (ต่างจากสคริปต์เดิมที่ต้อง `apk add` ทุกครั้งที่ start) |

---

## Golden image / รูปภาพฐาน

The image is built from `Dockerfile`:

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache rsync coreutils tzdata \
 && mkdir -p /var/log/rsync
ENV TZ=Asia/Bangkok
```

| Package | Purpose / ใช้ทำอะไร |
|---------|---------------------|
| `rsync` 3.4.x | data sync (`-avzPi --delete`) |
| `coreutils` | `md5sum` for integrity check |
| `tzdata` | correct timezone (`TZ=Asia/Bangkok`) |

You can build and push it to your own registry. Below is the full end-to-end
guide (build + upload + what to change in the YAML manifests).

---

## Build & upload the image to your registry / สร้างและอัปโหลด image ขึ้น registry

### Step 0 — Prerequisites / สิ่งที่ต้องเตรียม

- A container registry (e.g. **Harbor**, Docker Hub, private registry) reachable
  from all cluster nodes.
- A machine with **docker** CLI that can reach that registry.

Define two variables for the rest of this guide:

```bash
export REGISTRY=<REGISTRY_HOST>        # e.g. harbor.example.com:443 (NO scheme, NO trailing slash)
export PROJECT=<PROJECT>               # registry project/namespace, e.g. library (public) or rsync
```

### Step 1 — Login to the registry / เข้าสู่ระบบ

```bash
docker login $REGISTRY
# (Harbor: admin / <password>  หรือ robot account)
```

> If your registry is HTTP only (no TLS), configure the docker daemon first:
> `/etc/docker/daemon.json` → `{"insecure-registries": ["$REGISTRY"]}` then
> `systemctl restart docker`. Same for containerd on the k8s nodes (see below).

### Step 2 — Build the golden image / สร้าง golden image

From the repo root:

```bash
docker build -t $REGISTRY/$PROJECT/rsync-helper:1.0.0 .
```

### Step 3 — Tag an alias (optional) / ตั้ง tag สำรอง

```bash
docker tag $REGISTRY/$PROJECT/rsync-helper:1.0.0 $REGISTRY/$PROJECT/rsync-helper:latest
```

### Step 4 — Push / อัปโหลด

```bash
docker push $REGISTRY/$PROJECT/rsync-helper:1.0.0
docker push $REGISTRY/$PROJECT/rsync-helper:latest      # only if you tagged in step 3
```

Verify:

```bash
docker run --rm $REGISTRY/$PROJECT/rsync-helper:1.0.0 sh -c "which rsync && rsync --version | head -1"
# expect: /usr/bin/rsync  /  rsync  version 3.x
```

### Step 5 — Make the cluster nodes trust the registry / ให้ node ใน cluster ดึง image ได้

| Registry type | Node-side configuration |
|---------------|------------------------|
| HTTPS + valid cert | nothing (default) |
| HTTP (no TLS) — e.g. Harbor with `http://` | configure containerd `hosts.toml` (preferred) OR `insecure-registries` (deprecated) |
| Private project | add an `imagePullSecrets` to every pod (see below) |

For containerd with `config_path = "/etc/containerd/certs.d"` (HTTP registry):

```toml
# /etc/containerd/certs.d/<REGISTRY_HOST>/hosts.toml  (on EVERY node)
server = "http://<REGISTRY_HOST>"

[host."http://<REGISTRY_HOST>"]
  capabilities = ["pull", "resolve", "push"]
```

Then restart containerd and re-pull:

```bash
systemctl restart containerd && systemctl is-active containerd
```

**Private project + imagePullSecrets** — if `$PROJECT` is private:

```bash
kubectl -n <NAMESPACE> create secret docker-registry regcred \
  --docker-server=$REGISTRY \
  --docker-username=<USER> \
  --docker-password=<PASS> \
  --namespace=<NAMESPACE>
```

and add to each pod in the manifests:

```yaml
spec:
  imagePullSecrets:
    - name: regcred
```

> **Golden image concept / หลักการของ golden image:** packages (`rsync`,
> `coreutils`, `tzdata`) are baked in **at build time** — pods start instantly
> and need **no internet** to install anything (unlike the original scripts that
> ran `apk add` on every startup).

---

## Purposes / วิธีใช้

### MODE 1 — single Pod (simple, per-replica)

Located in `manifests/mode-single-pod/`

```bash
kubectl apply -f manifests/mode-single-pod/
```

Components:
- `00-namespace.yaml` — namespace `demo`
- `01-src-pvc.yaml` — source volume (RWO, storage-class of the source backend)
- `02-dst-pvc.yaml` — destination volume
- `03-log-pvc.yaml` — history log volume (usually on the dest storage class)
- `04-rsync-helper.yaml` — the rsync pod (uses the golden image, `restartPolicy: Never`)

Edit `04-rsync-helper.yaml`:
- `claimName` of `src` → the PVC you want to replicate **from**
- `claimName` of `dst` → the PVC you want to replicate **into**
- `nodeName` → the node where your app pod runs (needed when the source is RWO)
- `interval` (default 300s) / `--timeout` (default 10)

### MODE 2 — StatefulSet source (rsync for data coming from a StatefulSet)

Use this when your **source data lives inside a StatefulSet** (each replica owns
its own PVC, e.g. `data-filewriter-0/1/2`). We do **not** deploy rsync-helper as
a StatefulSet of its own — instead we create **one standalone Pod per replica**
(named `rsync-helper-N`) that pairs with `app-N` and mounts **its** PVCs directly.

Located in `manifests/mode-sts-source/` (example assumes the source STS
`filewriter` has **3 replicas**):

```bash
kubectl apply -f manifests/mode-sts-source/
```

Pairing pattern (see `manifests/mode-sts-source/01-README.md` for the full
table):

| app pod (STS)   | node          | rsync-helper pod    | src PVC             | dst PVC                 | log PVC             |
|-----------------|---------------|---------------------|---------------------|-------------------------|---------------------|
| `filewriter-0`  | `k8s-clus1-w1` | `rsync-helper-0`    | `data-filewriter-0` | `data-filewriter-nfs-0` | `rsync-helper-log-0` |
| `filewriter-1`  | `k8s-clus1-w2` | `rsync-helper-1`    | `data-filewriter-1` | `data-filewriter-nfs-1` | `rsync-helper-log-1` |
| `filewriter-2`  | `k8s-clus1-w1` | `rsync-helper-2`    | `data-filewriter-2` | `data-filewriter-nfs-2` | `rsync-helper-log-2` |

Each pod pins `nodeName` to the same node as its app pod (required because the
source is ReadWriteOnce). If your STS has a different replica count, copy
`04-rsync-helper-pod-0.yaml` per ordinal and adjust `metadata.name`, `nodeName`
and the three `claimName`s.

Read **`docs/sts-gotchas.md`** before using it — it explains why pods-per-replica
is preferred over a helper StatefulSet, and the pitfalls around StatefulSet
sources (PVC immutable naming, RWO co-location, scale-up/down, update strategy).

---

## YAML — what you must change before deploying / ต้องแก้ส่วนไหนบ้างก่อนใช้

The manifests use `<PLACEHOLDER>` values on purpose so you can adapt them to your
environment. Below is the **line-by-line checklist** for each file.

### Common — all files / ไฟล์ที่ทุกโหมดใช้เหมือนกัน

| File | Field | What to change / ต้องแก้เป็น |
|------|-------|------------------------------|
| `manifests/mode-single-pod/00-namespace.yaml` | `metadata.name` | namespace ของคุณ (default `demo`) |
| `manifests/mode-sts-source/00-namespace.yaml` | `metadata.name` | namespace ของคุณ |
| both `04-rsync-helper*.yaml` | `metadata.namespace` | ชื่อ namespace ตรงกับข้างบน |
| all PVC files | `metadata.namespace` | ชื่อ namespace เดียวกัน |
| all PVC files | `spec.storageClassName` | ชื่อ StorageClass ของ storage ปลายทาง/ต้นทางตามจริง |
| both `04-rsync-helper*.yaml` | `image:` | `<REGISTRY_HOST>/<PROJECT>/rsync-helper:1.0.0` → registry/project ที่ push ไปใน Step 4 |
| (private project) | `imagePullSecrets` | เพิ่ม `regcred` secret ตาม Step 5 |

### MODE 1 — `04-rsync-helper.yaml` (mapping data ของคุณ)

| Field | Where (approx. line) | What to change / ต้องแก้เป็น |
|-------|----------------------|------------------------------|
| `image:` | ~20 | registry/project ของคุณ (Step 4) |
| `nodeName:` | ~15 | node ที่ app pod เจ้าของ data อยู่ (จำเป็นถ้า source เป็น RWO) |
| `volumes[src] claimName` | ~159 | ชื่อ PVC **แหล่งข้อมูล** — เช่น `data-filewriter-0`, `mysql-data-iscsi` |
| `volumes[dst] claimName` | ~162 | ชื่อ PVC **ปลายทาง** — เช่น `data-filewriter-nfs-0`, `mysql-data-nfs` |
| `volumes[log] claimName` | ~165 | ชื่อ PVC บันทึก log (อยู่ SC ปลายทาง) |
| `volumeMounts[src] readOnly` | (ใน pod) | `true` แนะนำ — ป้องกันเขียนผิดที่แหล่งข้อมูล |
| `args` → `--timeout=` | ~55 | timeout rsync ต่อ file (default 10; เพิ่มเป็น 30-60 ถ้า data ใหญ่) |
| `args` → `sleep 300` | ~142 | รอบระหว่าง sync (default 300s) |
| `resources` | | ปรับ CPU/mem ถ้า volume ใหญ่ |

ตัวอย่างการแมปจริง (3 replicas = 3 manifest แยก — MODE 2 ใช้ pattern นี้เหมือนกัน):
สร้าง 1 manifest ต่อ ordinal โดยชี้ `rsync-helper-N → claimName data-<app>-N /
data-<app>-nfs-N` และ `nodeName` = node ของ `app-N`

### MODE 2 — `04-rsync-helper-pod-0.yaml` (+ pod-1, pod-2) — source จาก StatefulSet

| Field | Where | What to change / ต้องแก้เป็น |
|-------|-------|------------------------------|
| `image:` | ~28 | registry/project ของคุณ |
| `metadata.name` | ~8 | `rsync-helper-N` (จับคู่ ordinal app) |
| `nodeName:` | ~15 | node ที่ `app-N` อยู่ (ดูจาก `kubectl get pods -o wide`) |
| `volumes[src] claimName` | ~158 | PVC ของ app ordinal N (เช่น `data-filewriter-0/1/2`) |
| `volumes[dst] claimName` | ~161 | PVC ปลายทาง ordinal N (เช่น `data-filewriter-nfs-0/1/2`) |
| `volumes[log] claimName` | ~164 | PVC log ordinal N (`rsync-helper-log-N`) |
| `LOG_FILE` | args | ชื่อ log ต่อ ordinal (เช่น `sync-history-pod-2.log`) |

> สร้าง PVC ปลายทาง (`data-<app>-nfs-N`) ให้ครบก่อน apply — ไฟล์นี้ไม่มี
> volumeClaimTemplates (เป็น Pod ตัว ๆ อ้าง claimName ตรง ๆ)

### Checklist ก่อน apply / ตรวจก่อนคืน

```bash
grep -n '<PLACEHOLDER>\|<REGISTRY_' rsync_helper/manifests/ -r    # ต้องไม่เหลือ
kubectl apply --dry-run=client -f manifests/mode-single-pod/       # ทดสอบ syntax
```

---

## How the loop works / การทำงานของ loop

```
                       +----------------------+
                       |   src PVC (/src)     |   app writes here
                       +----------+-----------+
                                  |
                                  | rsync -avzPi --delete --timeout=10  (every 300s)
                                  v
                       +----------+-----------+
                       |   dst PVC (/dst)     |   replica / new backend
                       +----------+-----------+
                                  |
                                  | tee -a /var/log/rsync/sync-history*.log
                                  v
                       +----------+-----------+
                       |   log PVC (/var/log) |   history: BEFORE → CHANGE → AFTER → MD5
                       +----------------------+
```

Each iteration logs:
1. `Files BEFORE sync` (listing of /src and /dst)
2. rsync output
3. `CHANGE SUMMARY` (new / modified / deleted / dirs / total bytes)
4. `rsync exit code`
5. `Files AFTER sync`
6. `MD5 integrity check` (every file → OK / MISMATCH)

---

## Reducing downtime / ลดเวลาหยุดงาน

| EN | TH |
|----|----|
| Run rsync-helper continuously before cutover so /dst is fresh. | รัน rsync-helper ต่อเนื่องก่อน cutover เพื่อให้ /dst ทันสมัย |
| Right before switch, run one final rsync to catch last writes, **pause the app**, then point the new deployment to /dst. | ก่อนเปลี่ยน ให้รัน rsync ครั้งสุดท้าย + **หยุด app** แล้วชี้ deployment ใหม่ไปที่ /dst |
| Keep the old PVC for rollback (do not delete it during migration). | เก็บ /src ไว้เผื่อ rollback — ห้ามลบระหว่าง migration |
| Only delete the source after you have verified the new backend. | ลบ /src ต่อเมื่อ verify /dst เรียบร้อยแล้วเท่านั้น |

---

## Verification / การตรวจสอบ

```bash
# live pod log
kubectl logs -n <ns> <rsync-helper-pod> -f

# history file inside the log volume
kubectl exec -n <ns> <rsync-helper-pod> -- tail -40 /var/log/rsync/sync-history-*.log

# manual one-shot sync
kubectl exec -n <ns> <rsync-helper-pod> -- rsync -avzPi --delete /src/ /dst/

# manual MD5 spot-check
kubectl exec -n <ns> <rsync-helper-pod> -- sh -c 'md5sum /src/* | sort && md5sum /dst/* | sort'
```

Expect: `[ALL N FILES OK - data integrity verified]` at the end of each iteration.

---

## Project layout / โครงสร้างโครงการ

```
rsync_helper/
├── Dockerfile
├── README.md
├── LICENSE
├── bin/rsync-loop.sh                 # loop script (extracted from the manifests)
├── manifests/
│   ├── mode-single-pod/              # MODE 1 — per-replica standalone Pod
│   │   ├── 00-namespace.yaml
│   │   ├── 01-src-pvc.yaml
│   │   ├── 02-dst-pvc.yaml
│   │   ├── 03-log-pvc.yaml
│   │   └── 04-rsync-helper.yaml
│   └── mode-sts-source/              # MODE 2 — rsync สำหรับ source ที่มาจาก StatefulSet
│       ├── 00-namespace.yaml
│       ├── 01-README.md              # pairing map (ตัวอย่าง 3 replicas) + วิธีปรับ N replicas
│       ├── 04-rsync-helper-pod-0.yaml
│       ├── 04-rsync-helper-pod-1.yaml
│       └── 04-rsync-helper-pod-2.yaml
└── docs/
    └── sts-gotchas.md                # ⚠️ must-read for StatefulSet users
```

---

## License

MIT — see [LICENSE](LICENSE).