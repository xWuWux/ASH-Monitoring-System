"""Gunicorn lifecycle hooks for Prometheus multiprocess metrics.

The API image runs four sync workers.  ``prometheus_client`` writes each
worker's counters to a mmap file under ``PROMETHEUS_MULTIPROC_DIR``; those
files must be removed at master start and the dead worker's files marked
after a worker exits, or a scrape keeps adding stale values forever.

This file is intentionally dependency-free: Gunicorn imports it in the
master process, where the Prometheus package is available from the image's
requirements, but the hooks also quietly no-op when multiprocess mode is not
configured.
"""

import glob
import os


def _multiproc_dir():
    return os.environ.get("PROMETHEUS_MULTIPROC_DIR")


def on_starting(_server):
    """Remove mmap files left by a previous container/process generation.

    Domain: no-op unless ``PROMETHEUS_MULTIPROC_DIR`` is set.  Only files
    directly inside that directory are removed; the directory itself is
    created by the image and must be writable by the worker user.
    """
    directory = _multiproc_dir()
    if not directory:
        return
    os.makedirs(directory, exist_ok=True)
    for path in glob.glob(os.path.join(directory, "*.db")):
        try:
            os.unlink(path)
        except OSError:
            # A file can disappear between glob() and unlink().  Starting
            # with one stale file is preferable to failing the whole boot.
            pass


def child_exit(_server, worker):
    """Mark a worker's mmap files dead after it exits.

    Domain: no-op unless ``PROMETHEUS_MULTIPROC_DIR`` is set.  ``worker.pid``
    is Gunicorn's worker process ID; prometheus_client uses it in the
    filename.
    """
    if not _multiproc_dir():
        return
    from prometheus_client import multiprocess

    multiprocess.mark_process_dead(worker.pid)
