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

You can build and push it to your registry:

```bash
# rebuild & re-tag
docker build -t <registry>/library/rsync-helper:1.0.0 .
docker tag <registry>/library/rsync-helper:1.0.0 <registry>/library/rsync-helper:latest
docker push <registry>/library/rsync-helper:1.0.0
docker push <registry>/library/rsync-helper:latest
```

> Verified with a **public** Harbor registry at `http://10.10.110.8` inside this
> lab. With Harbor's `library` project (public), pods can pull without any
> imagePullSecrets. For a private project, add `imagePullSecrets` to the pod.

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

### MODE 2 — StatefulSet (scalable, STS-aware)

Located in `manifests/mode-statefulset/`

```bash
kubectl apply -f manifests/mode-statefulset/00-namespace.yaml
# create headless service first (see docs):
kubectl apply -f manifests/mode-statefulset/04-rsync-helper-headless-service.yaml  # adjust
kubectl apply -f manifests/mode-statefulset/04-rsync-helper-statefulset.yaml
```

This deploys the same loop as a `StatefulSet` with `podManagementPolicy: Parallel`.
Read **`docs/sts-gotchas.md`** before using it — there are 7 important pitfalls
(PVC immutable naming, `restartPolicy: Always`, RWO co-location, required headless
Service, scale-down vs PVC deletion, updateStrategy, adoption rules).

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
│   └── mode-statefulset/             # MODE 2 — StateSet-aware
│       ├── 00-namespace.yaml
│       ├── 01-README.md              # adoption & naming rules
│       ├── 02-src-pvc-0.yaml
│       ├── 03-dst-pvc-0.yaml
│       ├── 04-rsync-helper-statefulset.yaml
│       └── 05-log-pvc.yaml
└── docs/
    └── sts-gotchas.md                # ⚠️ must-read for StatefulSet users
```

---

## License

MIT — see [LICENSE](LICENSE).