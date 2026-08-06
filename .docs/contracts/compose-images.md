# Compose Images, Archives, and Registry Contract

## Image policy

Every service uses an immutable digest for deployment evidence. A submitted tag
may be retained as operator intent, but the accepted revision records the
resolved repository digest and local image ID. Builds on the managed host are
rejected.

## Public pull

`v-pull-docker-image` accepts owner and image reference, uses the owner's
protected Docker config, pulls explicitly, verifies the resulting reference,
architecture, and image ID, and records a redacted audit event. Policy may
restrict registries and image patterns by profile.

## Private registries

Registry credentials live in:

```text
/usr/local/vesta/data/users/<user>/docker-registry/config.json
```

The directory/file are root-owned 0700/0600. Password/token input is supplied
by file, never argv. Docker operations set `DOCKER_CONFIG` to that directory.
List and web interfaces return registry host, username label if approved,
created/rotated timestamps, and last validation result—never `auth`, password,
identity token, or raw config.

## Local archives

Image loading requires:

- a regular non-symlink archive in a root-controlled staging directory;
- a separately supplied SHA-256 file with exactly one allowed filename;
- successful `sha256sum -c`;
- archive size within the administrator limit;
- `docker image load` output parsed without treating it as identity proof;
- post-load inspection of architecture, OS, image ID, tags, and repo digests;
- policy approval of the resulting identity.

Archives are not committed or placed in user backups. Temporary archives are
removed after a successful load unless the operator requests retained
quarantine storage.

## Updates and rollback

Update resolves/pulls images before runtime mutation. The prior revision
records exact image IDs. Rollback refuses if a required prior image is absent
unless it can be pulled by digest; it never silently substitutes a newer tag.

Registry trust evidence, SBOM/provenance attachments, verifier modes, and
manifest-only update detection are defined by
[Compose trusted delivery](compose-trusted-delivery.md).
