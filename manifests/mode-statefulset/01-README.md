# ⭐ README — StatefulSet mode (MODE 2)
#
# วิธีแปลง rsync-helper ให้เป็น StatefulSet ได้อย่างปลอดภัย + adoption rules
#
# ─────────── 1. volumeClaimTemplates สร้าง PVC ชื่ออัตโนมัติ ───────────
#   ชื่อ = <template-name>-<sts-name>-<ordinal>
#   จาก 04-rsync-helper-statefulset.yaml:
#     template "src"  → src-rsync-helper-0, src-rsync-helper-1, ...
#     template "dst"  → dst-rsync-helper-0, dst-rsync-helper-1, ...
#     template "log"  → log-rsync-helper-0, ...
#
#   ⚠️ เปลี่ยนชื่อ PVC ที่ STS สร้างไม่ได้ (immutable) — ถ้าอยากได้ชื่อ custom:
#      (ก) pre-create PVC ด้วยชื่อเป๊ะตาม pattern ข้างบน แล้ว STS จะ "adopt" พอ apply
#      (ข) หรือ mount ด้วย claimName อ้าง PVC ที่มีอยู่แล้ว (sample ด้านล่าง)
#
# ─────────── 2. ตัวอย่าง: อยาก mount PVC ที่ app STS เดิมสร้างไว้ ───────────
#   สมมติ app STS "filewriter" มี PVC: data-filewriter-0, data-filewriter-1, ...
#   แก้ volumeClaimTemplates เป็น volumes: (ไม่ใช่ template) แล้ว reference:
#
#   spec:
#     volumeClaimTemplates: []        # ลบทิ้งได้
#     template:
#       spec:
#         volumes:
#           - name: src
#             persistentVolumeClaim:
#               claimName: data-filewriter-$(ordinal)   # ❌ ใช้ไม่ได้! claimName เป็น static
#           …
#
#   ⚠️ claimName ต้องเป็น static → วิธีที่ใช้ได้จริง คือ สร้าง PVC ก่อนแบบ ordinal
#      แล้วใช้ STS ของ rsync-helper สร้าง template src/dst/log ปกติ → แล้วใช้
#      static PV (volumeName) ผูกกับ PVC ที่ app สร้างไว้ (ดู sts-gotchas.md ข้อ 7)
#
# ─────────── 3. RWO co-location ───────────
#   ถ้า source เป็น ReadWriteOnce ต้องให้ rsync-helper-N ตก node เดียวกับ app pod N
#   วิธีง่ายสุด: set nodeName ต่อ ordinal (แต่ STS สร้าง template เดียว → ใช้ nodeAffinity
#   หรือ spread ตาม topology — demo4 แก้ด้วย Pod ตัว ๆ (MODE 1) แทน)
#
# ─────────── 4. pre-created PVC (adoption) ───────────
#   ถ้า pre-create เอง: ชื่อ/accessMode/storageClassName ต้องตรง template เป๊ะ ไม่งั้นไม่ adopt
#   ตัวอย่าง PVC จริง (src-rsync-helper-0) ให้ปรับ SC ตามจริงก่อน apply