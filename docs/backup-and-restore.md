# Backup and restore on `o700`

This is a runbook. If something is broken right now, start at section 1 and
ignore the rest until it is fixed.

Everything here is implemented by `systems/o700/backup.nix`, driven by the
`seta.<service>.backup` manifest declared in `systems/o700/services-*.nix`.
Where this document makes a claim, the file and option that implements it is
named so you can check rather than trust.

---

## 1. In an emergency

| Situation | Do this |
|---|---|
| One service is broken or its data is wrong | `just restore-o700 <set>` — restores the newest snapshot |
| You want an older state | `just backup-status-o700`, then `just restore-o700 <set> <snapshot-id>` |
| You deleted one file and want it back | `ssh o700`, then `sudo o700-restic-local mount /mnt/restore` and copy it out |
| The root disk is gone, the machine still boots | Section 7 |
| The whole machine is gone | Section 7, reading from `--repo offsite` |
| A backup alert arrived on Telegram | `ssh o700 journalctl -u o700-backup -n 100` |

**Always dry-run first.** Nothing in a restore is reversible:

```
just restore-o700 paperless latest --dry-run
```

**The one thing not to do:** do not restore a snapshot into a service whose
package has been upgraded since, without reading section 6. The tooling will
refuse and tell you why; do not reach past it with `--allow-version-skew`
because you are in a hurry.

---

## 2. What is and is not backed up

Ten backup sets. Each one is a restic tag, and each one restores independently.

| Set | What it holds | Database |
|---|---|---|
| `postgres` | Cluster roles and grants, plus a dump of every database | — |
| `gitea` | Repositories, LFS, attachments, `custom/conf` secrets | `gitea` |
| `mealie` | Recipe images and assets | `mealie` |
| `n8n` | Encryption-key check file, binary data, community nodes | `n8n` |
| `odoo` | The filestore — every `ir.attachment` binary | `odoo` |
| `opencloud` | Blobs, spaces/shares metadata, the idm store, `/etc/opencloud` | — |
| `paperless` | Originals, archive, thumbnails, the Django secret key | `paperless` |
| `vaultwarden` | Vault database, attachments, sends, the JWT signing key | SQLite |
| `kavita` | Reading progress, covers, bookmarks, the token key | SQLite |
| `kavita-library` | The book and manga files themselves | — |

**Deliberately not backed up: the Jellyfin movie and TV library.** It is the one
class of data on this host treated as re-sourceable, and it is far larger than
everything above put together. This is a decision, not an oversight — do not
"fix" it. Books and manga are *not* in that class, which is why
`kavita-library` exists as its own set.

**Not backed up here, but not lost either:** the configuration repository. It
lives in git and is cloned on `big-boss`. Section 7 depends on that.

### The secrets that only exist on disk

None of these are in agenix or the Nix store. Each is generated **once**, on
first start, and then reused forever — **nothing rotates them**. That is the
fact the rest of this section rests on: if they rotated, losing one would be a
non-event, and much of this list could be ignored.

All of them fall inside a backed-up path. This list exists so nobody "tidies up"
an exclude pattern and cuts one out.

They are not equally important, and the difference is the difference between an
inconvenience and permanent data loss.

#### Tier 1 — the key decrypts data at rest

Lose one of these and the data it protected is **unrecoverable**, even with a
perfect database restore. The ciphertext is in the backup; the key is what is
missing.

| File | What becomes unreadable |
|---|---|
| `/var/lib/gitea/custom/conf/secret_key` | Database columns Gitea encrypts with it: TOTP secrets, OAuth2 application client secrets, Actions secrets. Every 2FA-enrolled user is **locked out** — not prompted to re-login, but unable to finish logging in. Recovery is an admin disabling 2FA per user from the CLI. |
| `/etc/opencloud/opencloud.yaml` | `machine_auth_api_key`, `transfer_secret`, and the system user id that owns space metadata. The instance does not function. |
| `secrets/n8n-encryption-key.age` (in agenix, not on disk) | Every stored n8n credential. Listed here because a database-only restore of n8n has exactly this failure mode. |

The exact columns Gitea encrypts with `SECRET_KEY` vary between versions. Verify
against the running version before relying on the specifics.

#### Tier 2 — the key only signs short-lived tokens

Lose one of these and **everybody re-authenticates once**. Nothing is destroyed.
Worth restoring because it makes a recovery invisible to users rather than an
all-hands event, but not worth panicking over.

| File | Cost of losing it |
|---|---|
| `/var/lib/vaultwarden/rsa_key.pem` | One re-login per device. **The vault data is safe regardless** — it is encrypted client-side under each user's master password and this key is not involved. |
| `/var/lib/paperless/nixos-paperless-secret-key` | Session cookies and password-reset links. Passwords survive (PBKDF2, per-password salts), and API tokens survive too — those are random `authtoken` rows, not derived from `SECRET_KEY`. |
| `/var/lib/gitea/custom/conf/oauth2_jwt_secret` | Third-party OAuth integrations re-authorise. |
| `/var/lib/gitea/custom/conf/lfs_jwt_secret` | Nothing. These tokens live for minutes. |

#### Neither — operational

| File | Cost of losing it |
|---|---|
| `/var/lib/gitea/custom/conf/internal_token` | Authenticates the git hook binary calling back into the server. A mismatch breaks pushes until it is corrected. |
| `/var/lib/kavita/secrets/tokenkey` | Kavita **will not start**: the unit takes it via `LoadCredential` and nothing recreates it. Generate a new one (`head -c 64 /dev/urandom | base64 --wrap=0`) and the service comes back; users re-login. |

---

## 3. Where the data lives

Two restic repositories, holding the same snapshots:

- **local** — `/mnt/ex-ssd/backup/restic` (`PATHS.RESTIC_REPO`), on the external
  SSD. Not on the root disk: the root disk is the thing most likely to be lost,
  and a backup that dies with its source is not one.
- **offsite** — Backblaze B2 over its S3-compatible endpoint
  (`BACKUP.b2Bucket` / `BACKUP.b2Endpoint` in `STATIC_GLOBAL_VARS.nix`).

Both use the same password, from `secrets/restic-password.age`. B2 credentials
are in `secrets/restic-b2.age`.

### Encryption

**restic encrypts everything client-side, before anything leaves the host.**
There is no unencrypted mode to accidentally be in. AES-256-CTR for
confidentiality, Poly1305-AES for authentication, so a modified pack fails
verification rather than decrypting to garbage.

Each repository has its own randomly generated master key, wrapped by scrypt
over the repository password. Encrypted: file contents, **file names and
paths**, all metadata, the index, and the snapshot records. B2 never sees a
filename.

Not hidden: the number of pack files, their sizes, and when they were uploaded.
B2 can infer roughly how much is stored and how often it changes. Nothing about
what it is.

Three consequences worth being explicit about:

- **The local repository is encrypted too.** "Local" reads as plaintext to most
  people. It is not — if that SSD leaves the building, its contents are as
  opaque as the copy on B2.
- **The egress proxy cannot see backup contents, by construction.** tinyproxy
  gets a `CONNECT s3.….backblazeb2.com:443` and tunnels bytes; TLS terminates at
  B2, and what is inside it was already encrypted by restic. The proxy log
  records that a transfer happened and to whom, which is all it was ever meant
  to do.
- **Losing the password loses the data.** There is no recovery path, no escrow
  inside restic, no support ticket. This is why the `operating` key in section 7
  is load-bearing rather than a convenience.

That last point cuts both ways, and the plan should not oversell the scoped B2
key: restricting the application key limits what a compromised `o700` can reach
*elsewhere in the account*, but anyone holding the repository password and read
access to the bucket has everything in it — including the Vaultwarden database.
The password is the boundary, not the bucket policy.

Staging — `/mnt/ex-ssd/backup/staging/<set>` (`PATHS.BACKUP_STAGING`) — is where
database dumps and the version manifest are written before restic archives
them. It is wiped after every run. It is deliberately not inside the repository:
restic refuses to back up a path inside its own repo.

**Staging is the one place plaintext exists on disk.** For the minutes between
the prepare step and the cleanup, `/mnt/ex-ssd/backup/staging/` holds
unencrypted `pg_dump` output and a verbatim copy of the Vaultwarden and Kavita
SQLite databases. It is `0700 root:root` (a tmpfiles rule in
`systems/o700/backup.nix`) and removed at the end of every run, including a failed
one — `backupCleanupCommand` runs in `postStop`. Do not relocate it somewhere
group-readable, and do not add it to any share.

### `/var/lib/private` — read this before adding a service

`mealie`, `n8n` and `odoo` run with `DynamicUser = true`. For those three,
`/var/lib/<service>` is a **symlink** into `/var/lib/private/<service>`, and
**restic archives a symlink as a symlink**. Backing up `/var/lib/mealie` produces
a snapshot that succeeds, reports a plausible file count, and contains no data.

The backup sets therefore name the `/var/lib/private/...` path directly. Check
this every single time you add a service:

```
ssh o700 readlink /var/lib/<service>
```

If that prints a path, back up the path it printed.

### Ownership, and why restores put it back by hand

`o700-restore` reads the current owner of each path with `stat` before it stops
anything, and chowns back to it at the end.

**The reason is bare-metal recovery, not `DynamicUser`.** System uids are
allocated in whatever order the modules are evaluated, so a rebuilt host can
hand `gitea` or `paperless` a different uid than the one in the snapshot. restic
restores the recorded uid faithfully — which on a rebuilt host means a service
that cannot read its own state directory. Reading the current owner first is
what survives that.

**`DynamicUser` needs no compensation at all**, which is worth knowing because
the obvious assumption is the opposite. You will see this on the host:

```
# ls -la /var/lib/private/odoo/data
drwxr-xr-x  5 nobody nogroup  4096  filestore
```

That is not a stopped service or a stale uid. With id-mapped mounts — which this
kernel supports — systemd leaves the state directory owned by `nobody` (65534)
in the **host** namespace permanently, and maps it to the dynamic uid only
inside the service's own namespace (`systemd.exec(5)`, under `DynamicUser=`). So
the uid restic records is 65534 every night, it is stable across reboots, and
the snapshot is never stale. From the host's point of view there is no rotating
uid to compensate for.

---

## 4. The nightly run

One timer, at 02:00, `Persistent = true` so a missed night is caught up rather
than skipped.

```
o700-backup.timer
  └─ o700-backup.service          orchestrator, Nice=19, IOSchedulingClass=idle
       ├─ restic-backups-postgres        ─┐
       ├─ restic-backups-gitea            │  one at a time,
       ├─ …                               │  in a fixed order
       ├─ restic-backups-opencloud        │
       ├─ restic-backups-kavita-library  ─┘
       └─ o700-backup-offsite             restic copy → B2

o700-backup-prune.timer   Sunday 06:00
  └─ o700-backup-prune.service    forget per tag, prune, check 5% of the data
```

**Why serial, and why you must not "optimise" it.** Every source path except the
media library is on the 7200 RPM root spindle. This host has already been taken
down once by I/O contention on that disk — read the `swapDevices` comment in
`systems/o700/hardware-configuration.nix` for the incident. Nine restic jobs on
overlapping timers is that failure again. The orchestrator exists to make
concurrency impossible.

**Failures are counted, not fatal.** The orchestrator runs every set even if an
earlier one failed, and exits with the number of failures. `o700-backup` is in
`infraCriticalUnits` (`systems/o700/monitoring/notify.nix`), so a non-zero exit
sends the journal tail to Telegram. Same idiom as `host-audit`.

**OpenCloud is stopped for its own backup.** It is the only set with
`stopUnits = true`. It has no `pg_dump` equivalent — its state is embedded
bbolt/jsoncs3/nats stores with no snapshot API — and both filesystems here are
ext4, so there is no filesystem snapshot to take instead. A live copy would give
you correct blobs and torn metadata, which is not a recoverable instance. The
restart is wired through `backupCleanupCommand`, which systemd runs in
`postStop`, so **the service comes back even when the backup fails**. It is
scheduled second-to-last so the downtime lands at the end of the window.

**Consistency comes from ordering, and the order is the counter-intuitive one.**
Every set dumps its database *first* and archives blobs *second* — the reverse
of the order the applications write in.

That reversal is the whole point. Every one of these applications writes the
file *before* it commits the row that references it; it has to, or the row would
be visible while the data behind it did not exist. Odoo writes the filestore
entry then flushes `ir_attachment`, Paperless writes into `media/documents/`
inside the transaction that creates the `Document`, Vaultwarden writes the
attachment then inserts. So a backup must capture them the other way round.

Worked through, with a document scanned at 02:10 during an 02:00–02:30 run:

| | Dump first (what runs) | Files first |
|---|---|---|
| Row committed 02:10 | **not** in the 02:00 dump | **is** in the later dump |
| File written 02:10 | **is** picked up by the later scan | **not** — the scan already passed |
| Restore gives you | an unreferenced file on disk | a document whose PDF 404s |

The rule, so it can be checked rather than remembered: if B references A and the
application writes A then B, capturing B at `t_B` and A at `t_A` is safe only
when `t_B <= t_A`. B is the database, so the database goes first. The intuition
that misleads here is "get the files safe first" — but a *later* file scan is a
*bigger* file set, so capturing files last is what makes them cover the dump.

**What this does not cover: deletion.** The argument above is about concurrent
*writes*. Deletion is the mirror image — a document deleted at 02:10 leaves its
row in the 02:00 dump while the file is gone before the scan reaches it, which
is a dangling reference. The two orderings are symmetric, and choosing one is a
bet on which is more frequent. Creations vastly outnumber deletions in Paperless,
Odoo and Gitea, and at 02:00 both are close to zero, so dump-first is the better
bet — but it is a bet, not a proof.

If that residual matters for a particular service, the fix is not to flip the
order (that trades a common failure for a rare one). It is `stopUnits = true`,
which removes the window entirely, at the cost of downtime — which is exactly
the trade OpenCloud already makes.

**The offsite copy goes through tinyproxy**, like all other egress on this host.
Nothing needed opening: `ConnectPort = [ 443 ]` permits it and the filter is a
blocklist. Leave it that way — the gain is that a multi-gigabyte transfer to a
third party appears in the same log as every other outbound request.

### Reading a failure

```
ssh o700 journalctl -u o700-backup -n 100          # which set failed
ssh o700 journalctl -u restic-backups-<set> -n 100 # why
ssh o700 systemctl list-timers 'o700-backup*'      # when it last ran
```

---

## 5. Restoring one service

```
just restore-o700 <set> [<snapshot>|latest] [--dry-run] [--yes] [--repo offsite]
```

or on the host itself, `sudo o700-restore restore <set> <snapshot>`.

What it does, in order:

1. Resolves `latest` to a concrete snapshot id.
2. Pulls the staging payload — dumps and version manifest — into a scratch
   directory. **Nothing is stopped or overwritten yet**, because the version
   check in step 3 has to be able to refuse while the service is still running.
3. Runs the version guard (section 6).
4. Asks you to type the set name back, unless `--yes`.
5. Records the current owner of every target path.
6. Stops the set's units.
7. `restic restore --target / --delete` for each path. **`--delete` means files
   created after the snapshot are removed** — this is a revert, not a merge.
   That is usually what you want and occasionally not; `--dry-run` shows you
   exactly which files it is.
8. Drops and reloads each database with `pg_restore`, as the `postgres`
   superuser.
9. Installs the consistent SQLite copy and deletes stale `-wal`/`-shm`
   siblings, which would otherwise be replayed over the restored file.
10. Chowns back to what step 5 recorded.
11. Starts the units.

### What a restore does not bring back

Some state is deliberately excluded because it is regenerable and churns badly
in a deduplicating repository. That trade is only sound if the rebuild actually
happens, so it is listed here rather than left implicit.

| Service | Not restored | How it comes back |
|---|---|---|
| OpenCloud | The bleve search index | **Manual.** OpenCloud builds it from events, so a restored instance has an empty index and nothing triggers a rebuild. Run a reindex after restoring — confirm the exact subcommand with `opencloud search --help` on the host before relying on it. |
| Paperless | The Whoosh full-text index | `paperless-manage document_index reindex` |
| Paperless | The document classifier | Retrains itself on schedule; no action needed |
| Paperless | Celery Beat's schedule | Recreated on start. Deliberately not restored — a stale copy makes Celery fire every task it thinks is overdue |
| Kavita | `cache/`, `cache-long/` | Repopulated on demand |
| Gitea | The bleve code-search index, queue spool | Rebuilt from the repositories and the database |
| All | Thumbnails and preview caches | Regenerated on demand |

The OpenCloud row is the only one that needs a human. **Search will silently
return nothing until it is reindexed** — the service looks entirely healthy, so
this is worth doing as part of the restore rather than discovering later.

### One restore that can refuse to start: n8n

n8n compares `.n8n/config` against `N8N_ENCRYPTION_KEY_FILE` on every start and
**refuses to boot on a mismatch** ("Mismatching encryption keys"). Those two
values are a pair:

- `.n8n/config` comes out of the **backup** (`/var/lib/private/n8n/.n8n/config`)
- the key comes out of **agenix** (`secrets/n8n-encryption-key.age`), which is
  backed up separately with the config repo

They agree today because the agenix secret was lifted from that file rather than
generated fresh. Restoring one without the other — or rotating the agenix key
without replacing the file — gives a service that will not start. Fortunately
this fails loudly and immediately, which puts it in better company than the
silent Tier-1 failures above.

### Restoring the whole cluster

`o700-restore restore postgres <snap>` drops and recreates **every** database.
Its unit list is therefore every backed-up service on the host — they all get
stopped, because a database cannot be dropped while anything holds a connection.
Use it for a bare-metal rebuild, not to fix one service.

### Getting a single file out

```
ssh o700
sudo mkdir -p /mnt/restore
sudo o700-restic-local mount /mnt/restore     # ^C to unmount
```

Snapshots appear under `/mnt/restore/snapshots/`. Read-only, no service is
touched, and it is the right tool for "which version of this file did I want".

---

## 6. Restoring across a version upgrade

This is the one way a working backup still loses data.

**Older data under a newer binary is usually fine.** Gitea, Paperless, Mealie,
n8n, Vaultwarden and Kavita all run their migration framework on start —
Django `migrate`, alembic, TypeORM, diesel, EF Core. Loading an older database
is the ordinary upgrade path.

**These are the cases that break:**

| Case | What happens |
|---|---|
| Snapshot **newer** than the installed binary | Gitea refuses to boot; the Django/alembic apps partially apply and can corrupt |
| **Odoo** across a major | Community ships no migration scripts. An Odoo-18 database on an Odoo-19 binary is a hard break |
| **OpenCloud** across a major | Storage-layout revisions, no migration framework |
| **PostgreSQL** across a major | Dumps restore forward, never backward. Arrives with a channel bump, not a decision |

**Every snapshot records what produced it.** The prepare step writes a
`manifest` file next to the dumps containing the package version, the
PostgreSQL server version, `system.nixos.label`, and
`system.configurationRevision` — **the git commit of this repo that built the
running system**. That last field is the useful one: it survives
`just delete-generations` garbage-collecting the generation itself, which a
store path would not.

`o700-restore` compares before touching anything, and refuses on a downgrade or
any major mismatch. When it refuses it prints the way out:

```
git -C ~/.config/nixos checkout <rev> && just switch-o700
just restore-o700 <set> <snapshot> --yes
```

**On NixOS you restore the system and the data together.** That is the whole
answer, and for Odoo and OpenCloud it is the only correct order.

`--allow-version-skew` overrides the refusal. It is there for the case where you
have read the message and know something the guard does not. It is not there for
the case where you are in a hurry.

**The habit that avoids all of this:** run `just backup-then-switch-o700` for
any deploy that bumps a package version. It guarantees a snapshot taken under
the old binary exists — which is the only snapshot a restore can use without
argument.

---

## 7. Bare-metal recovery

The circular dependencies are real and they are the whole difficulty. **The
password manager, the git host and the config repo are all inside the thing you
are recovering.** Work in this order:

1. **Install NixOS** on the replacement disk. Any minimal installer.
2. **Get the `operating` age key onto the machine.** It lives on `big-boss`.
   Every secret in `secrets/` is encrypted to both the o700 host key *and*
   `operating` (`secrets/secrets.nix`) — the host key was on the disk you just
   lost, so `operating` is the only way in. Without it you cannot decrypt the
   restic password and the backups are unreadable.
3. **Clone the config from `big-boss`, not from Gitea.** Gitea is one of the
   things being restored. `big-boss` holds a current clone because the deploy is
   push-based.
4. **Restore the o700 host SSH key** or generate a new one and re-key the
   secrets with `agenix -r` from `big-boss`.
5. `just switch-o700` (or `just switch` locally). This brings up PostgreSQL,
   every service, and the backup tooling itself — with empty state.
6. **Restore `postgres` first.** It carries the cluster roles and grants that
   every per-service restore depends on for ownership.
   `sudo o700-restore restore postgres latest --repo offsite`
7. **Restore each service.** `vaultwarden` first if you need credentials for
   anything else.
8. **Verify before declaring victory.** Log into Vaultwarden, clone a repo from
   Gitea, open a document in Paperless, check Odoo's accounting.

If the SSD survived, use `--repo local` and it is far faster. Use `--repo
offsite` only when the local repository is gone too.

---

## 8. Adding a service to the backup

In the service's `seta` block:

```nix
seta.myservice = {
  backup = {
    enable = true;
    paths = [ "/var/lib/myservice" ];      # check readlink first!
    exclude = [ "/var/lib/myservice/cache" ];
    sqlite = [ ];                           # only for SQLite apps
    stopUnits = false;                      # only if it has no online dump
    keepYearly = 3;                         # 10 for anything with legal retention
  };
};
```

A service with `postgres = true` gets its database dumped and restored
automatically — there is no second option to set. That is what
`seta.<svc>.postgres` means; see its description in `modules/seta.nix`.

Then, and this is not optional:

```
ssh o700 readlink /var/lib/myservice                        # DynamicUser check
ssh o700 sudo systemctl start --wait restic-backups-myservice.service
ssh o700 sudo o700-restic-local ls latest --tag myservice | head -50
```

That third command is the one that catches the symlink trap. If it prints one
line, you backed up a symlink.

`host-audit` picks the new set up automatically — it derives the tags it expects
from `config.services.restic.backups`, so a set that stops producing snapshots
is reported as missing rather than silently dropping out of the check.

Keep excludes conservative. Everything excluded is something a restore has to
rebuild, and the cost of storing a few hundred megabytes of thumbnails is far
below the cost of discovering at restore time that something load-bearing
matched a pattern.

---

## 9. Retention, cost and pruning

Applied weekly by `o700-backup-prune.service`, per tag:

```
--keep-last 3 --keep-daily 14 --keep-weekly 8 --keep-monthly 12
--keep-yearly 3      (odoo, paperless, postgres: 10)
--group-by tags
```

`--group-by tags` matters: the default groups by host and paths, so changing a
set's `paths` would orphan every snapshot taken under the old list and keep them
forever.

**`odoo`, `paperless` and `postgres` keep ten years** because Greek statutory
retention governs them. Odoo carries the accounting and myDATA-relevant records;
Paperless mixes personal with association records, so the stricter business
retention governs the whole archive. Do not lower these to save space.

`prune` runs once, after all the `forget` calls, because it is the one restic
operation that rewrites pack files. `check --read-data-subset=5%` verifies a
rotating twentieth of the data each week — reading everything weekly is hours of
spindle I/O for a guarantee that costs twenty weeks and a twentieth of the load.

Size before it becomes an invoice:

```
ssh o700 sudo o700-restic-local stats --mode raw-data
```

B2 is roughly $6/TB/month stored, with egress free up to 3× stored bytes per
month.

### The B2 application key

restic needs exactly five capabilities:

```
listBuckets, listFiles, readFiles, writeFiles, deleteFiles
```

The B2 web console only offers three presets — Read+Write, Read, Write — and
"Read and Write" grants **eighteen**. The extras are not idle: they include
`writeBucketLifecycleRules`, `shareFiles`, `writeBuckets` and
`writeBucketReplications`, which respectively let a holder delete everything on
a schedule, publish signed download URLs for the backup data, make the bucket
public, and replicate it somewhere else.

Narrower keys can only be created from the CLI or the native API, not the
console:

```
b2 account authorize <masterKeyId> <masterKey>
b2 key create --bucket backup-o700 restic-b2     listBuckets,listFiles,readFiles,writeFiles,deleteFiles
```

(`b2 key create` on CLI v4; older versions spell it `b2 create-key`. Run it from
**big-boss**, not from o700 — the master key should never touch the host being
backed up.)

`deleteFiles` cannot be dropped. restic removes its own lock files, and
`o700-backup-prune` runs `forget --prune` against the offsite repository.

### What that does and does not protect

Enable "keep prior versions for 30 days" on the bucket. restic pack files are
immutable and only deleted at prune, so retaining old versions costs little, and
it recovers the realistic failure: a bad prune, or ransomware issuing S3
`DeleteObject` calls, which on a versioned bucket hides files rather than
destroying them.

**It is not absolute, and the plan should not pretend otherwise.** The same
credential holds `deleteFiles`, which via B2's native API can hard-delete
specific file versions — past the lifecycle rule. Narrowing the key removes the
lifecycle-tampering and data-sharing paths, which is worth doing, but it cannot
remove `deleteFiles` itself.

Genuine immutability needs B2 Object Lock, which conflicts with `prune` — pack
files could not be reclaimed until their retention expired. That trade has not
been made here. If the offsite copy ever needs to survive a fully compromised
`o700`, Object Lock plus never pruning offsite is the shape of the answer.

---

## 10. Verifying it still works

`host-audit` runs daily and reports to Telegram. It checks that every expected
tag has a snapshot newer than 48 hours locally and 72 hours offsite, and that
the SSD is mounted at all.

That catches a backup that stopped running. It does **not** catch a backup that
cannot be restored. For that, on a schedule you actually keep:

- `just restore-o700 mealie latest --dry-run` — cheapest possible check.
- A real restore of `mealie` (the least critical set), then log in and confirm
  recipes **and their images**. That pair is what proves the database and blob
  tiers were restored consistently with each other.
- `sudo o700-restore verify` — `restic check` on both repositories.
- Confirm the version guard still refuses when it should.

### Probing for a missing Tier-1 key

The tier-1 keys in section 2 fail **silently** at restore time, and this is the
part of verification that is easy to skip because everything looks fine.

A restore missing `secret_key` starts cleanly. The repositories are all there, a
`git clone` works, the web UI loads, the database is intact. Nothing reports an
error. You find out weeks later, when a 2FA user cannot log in — and by then the
snapshot that had the key may be past its retention.

So a clone is not the test. These are:

| Service | What to actually do | What it proves |
|---|---|---|
| Gitea | Log in as a **2FA-enrolled** user | `secret_key` still decrypts the TOTP column |
| Gitea | Push to a repo | `internal_token` matches, so the hooks work |
| OpenCloud | Open a shared space as a second user | `opencloud.yaml` is the one the metadata was written under |
| n8n | Open a workflow with a stored credential and run it | The agenix encryption key matches the database |

None of these are exercised by "the service came back up", which is the check
everybody actually performs.

Tier-2 keys need no probe. Their failure announces itself — everyone is logged
out, which is impossible to miss and costs nothing to fix.

**A backup nobody has restored from is not a backup.** Until a restore has been
done end to end at least once, treat everything in this document as a claim.

---

## 11. Known limits

- **RPO is 24 hours.** Anything created after the last 02:00 run is lost. If
  that becomes too coarse for Odoo, the answer is WAL archiving / pgBackRest, not
  a more frequent full backup.
- **Everything except OpenCloud is backed up live.** Databases are consistent
  (`pg_dump` and SQLite `.backup` both take proper snapshots), but blob
  directories are read while the service is running. The dump-then-scan order
  (section 4) makes a *created* blob an orphan rather than a dangling reference.
  It does not cover a *deletion* landing inside the backup window, which leaves
  the dump referencing a file the scan no longer found. Rare, and `stopUnits` is
  the way to eliminate it rather than trade it.
- **Both tiers depend on one key.** The `operating` age key on `big-boss` is
  what makes recovery possible without `o700`. If it is lost at the same time as
  `o700`, the backups are unreadable ciphertext. It is the single most valuable
  thing in this estate.
- **The local repository shares a disk with the media library.** Losing
  `/mnt/ex-ssd` loses the fast recovery path and leaves only B2.
- **`--keep-monthly 12` means a snapshot can be a year old**, spanning several
  application majors. The version manifest is what keeps that an asset rather
  than a trap — see section 6.
