# Compose Successor Production Promotion

Date: 2026-08-02 AEST

Status: **completed and independently accepted**

## Authorized boundary

The user authorized control-plane-only promotion to
`production.example.com` during the current maintenance window using
immutable tag `vesta-compose-product-corrections-20260801`, with the protected
`vxslave` quota migration included. No production backup, image-evidence
migration, workload restart/recreate, route/proxy/header edit, image pull/build,
secret/firewall change, or retirement of the stopped external rollback
authority was authorized or performed.

## Installed authority

- Tag: `vesta-compose-product-corrections-20260801`
- Tag object: `194986c9fa5dea17f9067b1b1c2ea07c4514ba0d`
- Release closeout: `bf4fb0107c1c97058bb6677408a5223ef7a9e381`
- Runtime/source: `8dc0dc9c0317d833d5aa57656ab0a180758a8df0`
- Runtime payload: 250 paths
- Payload SHA-256:
  `ff0fe05fa1637db3c3cc8c8b0f2763e47671cad754e1066b51e949f482e1dc46`
- Manifest SHA-256:
  `a84a0f778cf474565f772929a042fc05fd1117926a68961b1bed84f2d8893008`
- Path-list SHA-256:
  `e457d9f25d9623d93b4570a95b6f1147067cfeb723e6e1d3bfa77181410d3a64`
- Production transaction SHA-256:
  `7b9d936d04c0f288b9fbc8b98fb01754c9cc7e8f7b0e2c5ea56951763979f2d6`
- Transport manifest SHA-256:
  `f903865df897428dad6e2146bedd4bbfa6d788913ce3bba461bfd3ae5268c121`

The final transport manifest passed 7/7 strict checks. The exact 250 live
files match candidate hashes, modes, and `root:root` ownership.

## Deployment and recovery evidence

The release and exact project locks were held through every supervised
transaction. Early attempts failed closed before mutation on a missing `src`
allowlist root, host locale ordering, and two Git-derived baseline hashes. A
later payload attempt exposed nondeterministic raw Docker mount ordering;
rollback restored the exact prior source and production preflight passed. The
last pre-success attempt exposed a stale 2 MB storage counter: candidate
refresh measured 109 MB. It also rolled back exactly. Incident holders were
released only after protected audit records, exact source checks, complete
read-only preflight, and free-lock proof.

The successful transaction completed at `2026-08-01T23:26:17Z`:

- protected source rollback root:
  `/root/vesta-backups/pre-compose-successor-20260801T232552Z-8dc0dc9c`;
- protected quota rollback root:
  `/root/vesta-backups/vxslave-compose-quota-20260801T232552Z`;
- success `evidence.sha256` SHA-256:
  `14ec2d5fd8fbd55a741873f40645d88dab32735fdd83c045ad9e2104ceac1c42`;
- operation log SHA-256:
  `2748d5281f58bbbfdddc83594ac52e74264c036113c9025c4193e30b38865b7c`;
- quota rollback manifest SHA-256:
  `d93e8a2f4bdc057d97fd2b38ac03694c1f38bd6447358a081db2e5e803c58d69`;
- quota expected-data SHA-256:
  `a65bc106f66950f26cb79fecb12cd1fa7ed467c2fff87a8f5247decb264a00fe`.

All protected roots are `root:root` mode `0700`; protected files are mode
`0600` where specified.

## Final acceptance

Read-only acceptance script SHA-256
`69c33824ca5a86da124d40df07eb89e78d4f20f6d999b29ec36ccb1ddf820b87`
passed after transient-unit cleanup. Independent code and specification
reviews returned `CLEAR`.

A later documentation-closeout read-only acceptance (script SHA-256
`d793076f607154417df03a23d98347060f50217671163172b904cbe501839a12`)
passed 17/17 checks with the same runtime, revision, health, zero-restart,
109 MB quota-use, exact-source, evidence, guard, inventory, proxy, external
rollback-authority, and free-lock state.

- runtime marker: `8dc0dc9c`;
- `legacyadmin/legacy-admin-app`: revision 4, running and healthy, zero restarts;
- current plus revisions `000001`–`000004`: exact production five-field
  evidence bytes and valid revision manifests;
- managed and stopped external container projections: byte-equal to the
  canonical pre-change evidence, including start state, networks, mounts,
  volumes, selected Compose source/configuration, and image authority;
- external Compose source files: unchanged by protected SHA-256 manifest;
- Docker daemon PID and complete container/image/network/volume inventories:
  unchanged;
- native proxy and project authority manifests: unchanged; managed routes
  remain empty; no BusinessGUID value was read into a report;
- mount guard: exact candidate unit/drop-in, enabled and active, complete
  root-owned marker authority, protected owner root mounted;
- quota package: `vxslave-compose`; limits remain exact at
  `1/1/1.000/1024/256/1024/1/1/2`; refreshed storage use is 109 MB;
- stopped external no-build authority: preserved and exited;
- production Vesta backup run: no;
- workload mutation: no.

All transient promotion units were removed. Release and project locks are
free. Production remains on the accepted state above.

## Exact source rollback

No image build, pull, backup, evidence migration, or workload action is
needed. Under the release and project locks:

1. Verify the protected success root and its `evidence.sha256`.
2. Run the protected quota rollback script with
   `/root/vesta-backups/vxslave-compose-quota-20260801T232552Z`, then byte-check
   `rollback.pkg` against `data/packages/vxslave.pkg` and
   `rollback-user.conf` against `data/users/legacyadmin/user.conf`.
3. Disable/remove the exact mount-guard unit and Docker drop-in, reload
   systemd, scoped-unmount `/home/legacyadmin/docker`, restore its recorded
   device/inode/uid/gid/mode authority, and remove only the transaction-created
   legacy marker authority.
4. Restore `exact-release-files.tar`; remove only paths in protected
   `new-paths.txt`; restore runtime metadata.
5. Re-run the recorded old-runtime preflight and require revision 4 healthy,
   exact five-field evidence, unchanged proxy/project/source/container
   authority, old `vxslave` package/user bytes, and ordinary unmounted data
   root before releasing the locks.

The stopped external container remains the separate workload no-build
rollback authority and must not be started or retired without new explicit
authorization.
