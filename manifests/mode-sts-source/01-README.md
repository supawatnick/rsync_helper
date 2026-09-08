# ⭐ README — MODE 2: rsync กับ source ที่มาจาก StatefulSet (STS)

โหมดนี้ใช้เมื่อ **source data มาจาก StatefulSet** (เช่น `filewriter` ที่มี PVC
ชื่อ `data-filewriter-0/1/2` สร้างอัตโนมัติจาก volumeClaimTemplates)

## ทำไมต้องเป็น Pod ตัว ๆ (ไม่ใช่ StatefulSet ของ helper เอง)

- StatefulSet บังคับ `restartPolicy: Always` + ชื่อ PVC ถูก auto-gen —
  ยุ่งยากและเสี่ยง sync ผิดเมื่อ scale ออก
- การ sync ต่อ replica ทำง่ายสุดด้วย **Pod ตัว ๆ ต่อ ordinal** จับคู่กับ app pod N
  แล้ว pin node ให้ตรง (เพราะ source เป็น RWO ใช้ได้ node เดียว)

## ตัวอย่าง: source STS `filewriter` มี 3 replicas

ตัวอย่างในโฟลเดอร์นี้สร้างจาก distribution จริง (จำลองจาก lab):

| app pod (STS)   | node          | rsync-helper pod    | src (PVC)             | dst (PVC)             | log (PVC)             |
|-----------------|---------------|---------------------|-----------------------|-----------------------|-----------------------|
| `filewriter-0`  | `k8s-clus1-w1` | `rsync-helper-0`    | `data-filewriter-0`   | `data-filewriter-nfs-0` | `rsync-helper-log-0` |
| `filewriter-1`  | `k8s-clus1-w2` | `rsync-helper-1`    | `data-filewriter-1`   | `data-filewriter-nfs-1` | `rsync-helper-log-1` |
| `filewriter-2`  | `k8s-clus1-w1` | `rsync-helper-2`    | `data-filewriter-2`   | `data-filewriter-nfs-2` | `rsync-helper-log-2` |

> หมายเหตุ: ordinal 2 อยู่ node เดียวกับ ordinal 0 ได้ (RWO pin แค่ "node เดียวกัน"
> ไม่ได้หมายความว่าทุก ordinal ต้องคนละ node)

## วิธี apply

```bash
kubectl apply -f manifests/mode-sts-source/
```

จะสร้าง 3 Pods พร้อมกัน (คนละไฟล์ — ไม่มีลำดับบังคับ)

## การปรับใช้กับ STS ของคุณ (N replicas)

1. ดูว่า STS ของคุณมีกี่ replicas + แต่ละ `filewriter-N` อยู่ node ไหน:
   ```bash
   kubectl get pods -n <ns> -l app=<your-app> -o wide
   ```
2. ตรวจชื่อ PVC ที่ app ได้รับ:
   ```bash
   kubectl get pvc -n <ns> | grep <your-app>
   ```
3. copy `04-rsync-helper-pod-0.yaml` ต่อเป็น `pod-1`, `pod-2`, ... ตาม replicas แล้วแก้:
   - `metadata.name`   → `rsync-helper-N`
   - `spec.nodeName`   → node ของ `app-N` (ดูจาก step 1)
   - `claimName` src   → PVC ของ `app-N` (เช่น `data-<your-app>-N`)
   - `claimName` dst   → PVC ปลายทางของ `app-N`
   - `claimName` log   → `rsync-helper-log-N`
   - ชื่อใน `LOG_FILE` → ตาม ordinal (เช่น `sync-history-pod-2.log`)

## สิ่งที่ต้องระวัง

- **nodeName ต้อง match node ของ app pod เป๊ะ** — ถ้า source เป็น RWO pod จะ
  mount ไม่ได้ถ้าอยู่คนละ node (ดู `docs/sts-gotchas.md`)
- ถ้า app pod เคลื่อน node (like eviction) → ต้องอัปเดต nodeName ให้ตรง
  มิฉะนั้น helper pod รัน but mount fail (ยัง log เหลือ)
- `data-<app>-nfs-*` (dst) ต้อง **มีอยู่แล้ว** — สร้าง PVC ปลายทางก่อน apply pod
- scale STS ขึ้น → เพิ่ม pod file ตาม ordinal ใหม่; scale ลง → ลบไฟล์/ลบ pod ที่เกิน
- source mount เป็น `readOnly: true` (กันเขียนผิดที่แหล่งข้อมูล)

## หลักการจับคู่ (ordinal pairing)

ไฟล์ pod ตัว ๆ ทำงานได้เพราะ **ทุก pod แตะ PVC ต่างชื่อกัน** — ไม่ต้องรอให้
STS สร้างให้ (ต่างจาก helper-STS ที่ต้องใช้ pattern auto-gen). ผูกด้วยมือตาม
ตารางด้านบนพอ.