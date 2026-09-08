# rsync-helper with StatefulSet — Gotchas (Things to be careful about)

When using rsync-helper to migrate/replicate data for an application that runs
inside a **StatefulSet**, you must know the following. These pitfalls are the
reason the `mode-single-pod` (standalone Pod) approach is often simpler.

---

## 1. PVC names are immutable and auto-generated

StatefulSet creates PVCs using:

```
<volumeClaimTemplate.name>-<statefulset.name>-<ordinal>
```

Example: `volumeClaimTemplates.src` + `statefulset rsync-helper` → PVC `src-rsync-helper-0`.

- You **cannot rename** a PVC after it is created (`metadata.name` is immutable).
- If you need a custom name, pre-create the PVC with the exact generated name and
  the StatefulSet will *adopt* it on `apply`. Fields must match exactly
  (`storageClassName`, `accessModes`, capacity) otherwise adoption fails.

---

## 2. StatefulSet forces restartPolicy: Always — your loop must never exit

Standalone Pods (MODE 1) use `restartPolicy: Never`. **StatefulSet pods do not
accept `Never`**; they always use `Always`. If your script exits (even because
rsync failed), the container restarts, which can cause duplicate/overlapping
syncs or churn.

Design rules for the script inside a StatefulSet:

- Wrap everything in an infinite `while true` loop (the repo manifests already do this).
- **Never `exit 1` on rsync failure** — log the error and continue to the next iteration.
- Use `sleep <interval>` as the pacemaker so one run is bounded.

---

## 3. ReadWriteOnce (RWO) co-location problem

If the source PVC is `ReadWriteOnce` (RWO), it can only attach to **one node**.
The rsync-helper pod for table `N` must therefore run on the *same node* as the
application pod `N`.

| Approach           | How | Pros / Cons |
|--------------------|-----|-------------|
| `nodeName` in pod | Set the node explicitly | Simple, but hardcoded — used in MODE 1 |
| `nodeAffinity`     | Pin by `kubernetes.io/hostname` | Works in a single StatefulSet template, but all replicas share it → cannot differ per ordinal |
| Node/pod anti-affinity on the app's hostname | Let scheduler choose | Complex; still relies on knowing app placement |

> **Practical tip:** If you need per-ordinal node matching, a standalone Pod
> per replica (MODE 1) with an explicit `nodeName` is far simpler to reason
> about than a StatefulSet.

---

## 4. A StatefulSet always needs a headless Service

A StatefulSet requires `spec.serviceName` to point to a headless Service, even
if rsync-helper does not need DNS for anything else. Without it the StatefulSet
will not create pods.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: rsync-helper
spec:
  clusterIP: None          # headless
  selector:
    app: rsync-helper
```

(The 04-rsync-helper-statefulset.yaml relies on an existing `rsync-helper`
headless Service — create it first.)

---

## 5. Scaling down does NOT delete PVCs

- Scaling a StatefulSet down to fewer replicas leaves the PVCs behind (data is
  preserved — good for rollback).
- But the rsync-helper running for that ordinal disappears, so that replica's
  sync stops.
- Re-scaling up with `podManagementPolicy: Parallel` re-attaches the old PVC
  (same name) and resumes.

---

## 6. updateStrategy — be careful during migration

- Default `RollingUpdate` in StatefulSet **recreates pods one-by-one**, so
  rsync-helper pods get restarted mid-loop (each restarts its loop from iteration 1).
- If you apply a real update while a migration is running, use
  `updateStrategy: { type: OnDelete }` to control exactly when pods are replaced,
  or freeze the app (scale to 0) during the final sync.

---

## 7. Adoption & data-ownership rules

- A PVC pre-created for adoption must match the template's `storageClassName`,
  `accessModes` and requested capacity **exactly**.
- If rsync-helper's `src` must point at a PVC owned by *another* StatefulSet
  (e.g. `data-filewriter-0`), you cannot reference an ordinal variable inside
  `claimName`. You must either:
  - create a static PVC/PV pair that is bound to the app's underlying volume, or
  - mount the app's PVC into the *same* pod (sidecar pattern), not into a
    separate rsync-helper StatefulSet.

---

## Recommendation summary

| Scenario | Recommended mode |
|----------|------------------|
| Single replica, simple data copy | MODE 1 (single Pod) |
| Multiple replicas, source is RWO on fixed nodes | MODE 1 per replica with `nodeName` |
| Data in one StatefulSet, no RWO co-location pain | MODE 2 (StatefulSet) |
| Need sidecar-like mount of the app's own PVC | Sidecar container inside the app STS |