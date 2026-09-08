# rsync-helper with a StatefulSet source — Gotchas (Things to be careful about)

When you migrate/replicate data for an application that runs inside a
**StatefulSet**, this document explains why **rsync-helper itself is deployed
as standalone Pods (`manifests/mode-sts-source/`)** — one per replica — instead
of wrapping the helper in its own StatefulSet — and what to watch out for.

**Core decision:** MODE 2 does **not** create a helper StatefulSet. Each
`rsync-helper-N` Pod is a normal Pod (`restartPolicy: Never`) that mounts the
*application's* existing PVCs by name and pins `nodeName` to the same node as
`app-N`. The helper StatefulSet approach was rejected for the reasons below.

---

## 1. Making rsync-helper a StatefulSet of its own fights K8s rules

StatefulSet auto-generates PVC names with:

```
<volumeClaimTemplate.name>-<statefulset.name>-<ordinal>
```

If the helper were a StatefulSet, its `src` could never point at the app's
already-existing PVCs (`data-filewriter-0`) because `claimName` is a **static
value** — you cannot put a variable into it. You would be forced into awkward
workarounds (static PV rebinding, adoption tricks). That is why we simply
mount the app's PVCs directly from a standalone Pod instead.

---

## 2. StatefulSet forces restartPolicy: Always — standalone Pods use Never

- **Standalone Pods** (MODE 1 & MODE 2) can use `restartPolicy: Never`: the pod
  runs its sync loop, and if you want to stop syncing you delete the pod.
- **StatefulSet pods accept only `Always`**. Any script `exit` (even from an
  rsync failure) triggers an immediate restart → duplicate/overlapping syncs.

Rule for the script (works in both Pod modes): wrap everything in an infinite
`while true` loop, **never `exit` on rsync error**, and use `sleep <interval>`
as the pacemaker.

---

## 3. ReadWriteOnce (RWO) co-location — why each helper pins its node

A source PVC that is `ReadWriteOnce` can attach to **one node only**. Therefore
`rsync-helper-N` must run on the *same node* as `app-N` (e.g. `filewriter-0` is
on `k8s-clus1-w1` → `rsync-helper-0` must also be on `k8s-clus1-w1`).

| Approach | How | Verdict |
|----------|-----|---------|
| `nodeName` in each pod | Hardcode the node per file | ✅ Recommended — one pod per replica, each with its own `nodeName` (matches MODE 2) |
| `nodeAffinity` (`kubernetes.io/hostname`) | Pin by node label | Fine, but as a single pod per replica it is no better than `nodeName` |
| A helper StatefulSet + nodeAffinity | All replicas share one template | ❌ Cannot differ per ordinal — every pod would pin the same node |

> The easy way to know the node: `kubectl get pods -n <ns> -o wide` and copy the
> NODE column of `app-N` into `spec.nodeName` of `rsync-helper-N`.

---

## 4. A helper StatefulSet needs a headless Service — standalone Pods don't

StatefulSets require `spec.serviceName` → headless Service, even when the pod
does no networking. Standalone Pods have no such requirement — one fewer thing
to create and debug. (Not applicable to MODE 1 / MODE 2.)

---

## 5. Scaling the *source* StatefulSet changes the pair set

- Scaling the app STS **down** leaves its PVCs behind (data survives — good for
  rollback), but the data keeps changing only while `app-N` runs.
- If you can't stop the app during final sync, the ordinals that no longer exist
  simply don't need a helper.
- Scaling the app STS **up** → create additional `rsync-helper-N` files for the
  new ordinals (copy `04-rsync-helper-pod-0.yaml`, adjust `nodeName` + claims).

---

## 6. updateStrategy of the source app — control the churn

- Default `RollingUpdate` recreates app pods **one-by-one**. A recreated pod
  lands on the same node (its RWO PVC forces it), so the helper keeps working —
  but the app may briefly release/reattach the volume while rsync is running.
- For a clean final cutover: set `updateStrategy: { type: OnDelete }` or scale
  the app to 0, run a final rsync, verify MD5, then switch the app config to the
  destination storage.

---

## 7. Data ownership & rollback

- The helper only ever **reads** the source (`volumeMounts src → readOnly: true`)
  and **writes** to destination + its own log PVC.
- Keep the source PVCs during migration (do not delete them). Delete them only
  after you have verified the destination and run the app there for a while.
- Log PVC (`rsync-helper-log-N`) is unique per replica — use it to audit that
  every ordinal converged (`[ALL N FILES OK - data integrity verified]`).

---

## Recommendation summary

| Scenario | Recommended mode |
|----------|------------------|
| Single replica, simple data copy | MODE 1 (single Pod) |
| Source is a StatefulSet (N replicas), RWO volumes | MODE 2 — one standalone Pod per ordinal + `nodeName` |
| Need the helper inside the app pod's own netns | Sidecar container inside the app STS |
| Helper as its own StatefulSet | ❌ Avoid (PVC naming + restartPolicy fights) |