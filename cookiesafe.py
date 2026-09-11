#!/usr/bin/env python3
"""cookiesafe — TOCTOU-free cookie-store helper for OmaFinSight.

Owns the entire credential path: walks the directory chain with
openat(O_NOFOLLOW) retaining parent descriptors, validates every component
(owner==euid, dir, 0700 or stricter), validates the cookie jar as a
single-link regular file owned by euid with private mode, reads the jar
bytes from an already-opened fd (never reopening the pathname), and
publishes new jars via descriptor-relative O_EXCL random temp files with
fsync + atomic renameat2-style rename + directory fsync.

Subcommands:
  read   <dir-chain> <name>        -> writes jar bytes to stdout; exit 0
  write  <dir-chain> <name>        -> reads new jar bytes from stdin; publishes
  delete <dir-chain> <name>        -> removes the jar if valid
  check  <dir-chain> <name>        -> exit 0 if a valid jar exists, else non-zero

All validation is on open file descriptors; a swapped path component after
validation cannot affect in-flight operations.
"""
import os
import sys
import stat
import errno
import secrets

STATE_SUBPATH = ".local/state/omafinsight"

# Bound the cookie jar: a FinSight session cookie jar is ~350 bytes; 64 KiB
# is a generous ceiling that also bounds the read() for safety.
MAX_JAR_BYTES = 64 * 1024


def eprint(msg):
    print(msg, file=sys.stderr)


def home():
    h = os.environ.get("HOME", "")
    if not h or not h.startswith("/"):
        raise ValueError("HOME not set to an absolute path")
    return h.rstrip("/")


def open_dirfd_nofollow(parent_fd, name):
    """Open name under parent_fd with O_NOFOLLOW; return fd. Raises OSError."""
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)


def validate_dir_fd(fd, where):
    """fd must be a directory owned by euid with mode 0700 or stricter."""
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        raise ValueError(f"{where}: not a directory")
    if st.st_uid != os.geteuid():
        raise ValueError(f"{where}: not owned by current user")
    mode = stat.S_IMODE(st.st_mode)
    if mode & 0o077:
        raise ValueError(f"{where}: permissions too open ({oct(mode)})")
    return st


def validate_jar_fd(fd):
    """fd must be a regular file, single link, owned by euid, 0600 or stricter."""
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        raise ValueError("cookie jar: not a regular file")
    if st.st_nlink != 1:
        raise ValueError("cookie jar: multiple hard links")
    if st.st_uid != os.geteuid():
        raise ValueError("cookie jar: not owned by current user")
    mode = stat.S_IMODE(st.st_mode)
    if mode & 0o077:
        raise ValueError(f"cookie jar: permissions too open ({oct(mode)})")
    if st.st_size > MAX_JAR_BYTES:
        raise ValueError("cookie jar: implausibly large")
    return st


def validate_dir_fd_component(fd, name, strict):
    """Directory owned by euid. strict → 0700 exactly; else no group/other write."""
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        raise ValueError(f"{name}: not a directory")
    if st.st_uid != os.geteuid():
        raise ValueError(f"{name}: not owned by current user")
    mode = stat.S_IMODE(st.st_mode)
    if strict and (mode & 0o077):
        raise ValueError(f"{name}: permissions too open ({oct(mode)})")
    if not strict and (mode & 0o022):
        raise ValueError(f"{name}: group/other write ({oct(mode)})")


def open_state_dir():
    """Open ~/.local/state/omafinsight/<instance> with full no-follow walk.

    Creates missing components safely if absent (owner-only modes), then
    walks the chain so validation and use share the same descriptors.
    Returns (final_dir_fd, instance_name).
    """
    home_dir = home()
    instance = os.environ.get("__OMAFIN_INSTANCE__", "")
    if not instance or "/" in instance or instance in (".", ".."):
        raise ValueError("instance name missing or invalid")
    # Only allow the safe charset for instance dirnames.
    if not all(c.isalnum() or c in "._-" for c in instance):
        raise ValueError("instance name has invalid characters")

    base_fd = os.open(home_dir, os.O_RDONLY | os.O_DIRECTORY)
    try:
        # Walk/create: .local, state, omafinsight, <instance>
        chain = [".local", "state", "omafinsight", instance]
        current = base_fd
        try:
            for i, name in enumerate(chain):
                strict = i >= 2   # omafinsight/ and <instance>/ are ours → 0700
                try:
                    fd = open_dirfd_nofollow(current, name)
                    validate_dir_fd_component(fd, name, strict)
                except FileNotFoundError:
                    os.mkdir(name, 0o700, dir_fd=current)
                    fd = open_dirfd_nofollow(current, name)
                    validate_dir_fd_component(fd, name, strict)
                except OSError as e:
                    if e.errno == errno.ENOTDIR or e.errno == errno.ELOOP:
                        raise ValueError(f"{name}: not a private directory (symlink?)")
                    raise
                if current != base_fd:
                    os.close(current)
                current = fd
            return current, instance
        except Exception:
            if current != base_fd:
                os.close(current)
            raise
    finally:
        os.close(base_fd)


def read_jar(dir_fd, name):
    """Open the jar no-follow, validate, read from the same fd."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    try:
        validate_jar_fd(fd)
        chunks = []
        remaining = MAX_JAR_BYTES
        while remaining > 0:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def publish_jar(dir_fd, name, data):
    """Atomic, fsynced, descriptor-relative publication.

    Creates a random exclusive temp file in the SAME directory (no path
    traversal possible — the name never leaves the fd namespace), writes
    and fsyncs it, validates it, links it into place via a rename that
    cannot follow symlinks (the target is a name in a validated dirfd, and
    rename replaces atomically), then fsyncs the directory.
    """
    if len(data) > MAX_JAR_BYTES:
        raise ValueError("refusing to store oversized jar")
    for attempt in range(64):
        tmp = f".jar.{secrets.token_hex(8)}"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
            break
        except FileExistsError:
            continue
    else:
        raise ValueError("could not create temp jar")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != os.geteuid():
            raise ValueError("temp jar failed validation")
        os.write(fd, data)
        os.fsync(fd)
        os.close(fd)
        fd = None
        # Validate again post-close (paranoia; catches external races on the
        # temp name inside our own 0700 dir).
        vfd = os.open(tmp, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
        try:
            validate_jar_fd(vfd)
        finally:
            os.close(vfd)
        # Atomic publish. os.rename with dir_fd is renameat2-syscall-backed
        # and replaces the target atomically without following symlinks on
        # either end.
        os.rename(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        # fsync the directory so the rename is durable.
        dir_fd2 = os.dup(dir_fd)
        try:
            os.fsync(dir_fd2)
        finally:
            os.close(dir_fd2)
    except Exception:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.unlink(tmp, dir_fd=dir_fd)
        except OSError:
            pass
        raise


def cmd_read(dir_fd, name):
    data = read_jar(dir_fd, name)
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def cmd_write(dir_fd, name):
    data = sys.stdin.buffer.read(MAX_JAR_BYTES + 1)
    if not data:
        raise ValueError("no jar data on stdin")
    publish_jar(dir_fd, name, data)


def cmd_delete(dir_fd, name):
    # Validate the existing jar first (refuses to unlink arbitrary files).
    read_jar(dir_fd, name)
    os.unlink(name, dir_fd=dir_fd)
    dir_fd2 = os.dup(dir_fd)
    try:
        os.fsync(dir_fd2)
    finally:
        os.close(dir_fd2)


def cmd_check(dir_fd, name):
    read_jar(dir_fd, name)


def cmd_work(dir_fd, name, home_dir):
    """Create a random 0700 work dir INSIDE the validated instance dir.
    Prints the ABSOLUTE path for shell use. The walk already guaranteed the
    chain is real (no symlinks), so absolute == fd-resolved here."""
    for attempt in range(64):
        tmp = f".work.{secrets.token_hex(8)}"
        try:
            os.mkdir(tmp, 0o700, dir_fd=dir_fd)
            print(home_dir + "/" + STATE_SUBPATH + "/" + name + "/" + tmp)
            return
        except FileExistsError:
            continue
    raise ValueError("could not create work dir")


def cmd_rmtree(name, sub):
    """Remove a work dir created by cmd_work. Validates the name is exactly
    a .work.* immediate child of the instance dir (no traversal), then
    removes it through a no-follow walk."""
    if "/" in sub or not sub.startswith(".work."):
        raise ValueError("invalid work dir name")
    os.environ["__OMAFIN_INSTANCE__"] = name
    dir_fd, _ = open_state_dir()
    try:
        # Open the subdir no-follow, verify it's a dir owned by euid
        fd = os.open(sub, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
        try:
            validate_dir_fd(fd, sub)
            # Remove children by fd-relative name (all our files are known-safe,
            # but unlink via names with no traversal out of the dirfd).
            for entry in os.listdir(fd):
                os.unlink(entry, dir_fd=fd)
        finally:
            os.close(fd)
        os.rmdir(sub, dir_fd=dir_fd)
    finally:
        os.close(dir_fd)


def main():
    argv = sys.argv[1:]
    if len(argv) >= 2 and argv[0] == "rmtree":
        try:
            cmd_rmtree(argv[1], argv[2])
            return 0
        except Exception as e:
            eprint(f"cookiesafe: {e}")
            return 5
        finally:
            pass
    if len(argv) < 2 or argv[0] not in ("read", "write", "delete", "check", "work"):
        eprint("usage: cookiesafe.py {read|write|delete|check|work} <instance> | rmtree <instance> <dir>")
        return 2
    action, instance = argv[0], argv[1]
    os.environ["__OMAFIN_INSTANCE__"] = instance
    try:
        dir_fd, _ = open_state_dir()
    except Exception as e:
        eprint(f"cookiesafe: {e}")
        return 3
    jar_name = "session.txt"
    try:
        if action == "read":
            cmd_read(dir_fd, jar_name)
        elif action == "write":
            cmd_write(dir_fd, jar_name)
        elif action == "delete":
            cmd_delete(dir_fd, jar_name)
        elif action == "check":
            cmd_check(dir_fd, jar_name)
        elif action == "work":
            cmd_work(dir_fd, instance, home())
        return 0
    except FileNotFoundError:
        eprint("cookiesafe: no session store")
        return 4
    except Exception as e:
        eprint(f"cookiesafe: {e}")
        return 5
    finally:
        os.close(dir_fd)


if __name__ == "__main__":
    sys.exit(main())
