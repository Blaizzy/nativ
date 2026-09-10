import Foundation

/// Shared with the subprocess tests so capacity checks run before any transfer.
enum HuggingFaceDownloadPreflight {
    static let script = """
    import shutil
    print("__NATIV_STAGE__:preparing", flush=True)
    revision = sys.argv[4]
    files = snapshot_download(
        repo_id=sys.argv[1],
        revision=revision,
        cache_dir=sys.argv[2],
        dry_run=True,
        ignore_patterns=ignored_patterns,
    )
    if not files or any(item.file_size is None or item.file_size < 0 for item in files):
        raise RuntimeError("Could not verify the model's download size. Try again.")
    revisions = {item.commit_hash for item in files}
    if len(revisions) != 1 or not next(iter(revisions)):
        raise RuntimeError("Could not verify the model revision. Try again.")
    revision = next(iter(revisions))
    total_bytes = sum(item.file_size for item in files)
    cached_bytes = sum(item.file_size for item in files if not item.will_download)
    remaining_bytes = total_bytes - cached_bytes
    os.makedirs(sys.argv[2], exist_ok=True)
    available_bytes = max(shutil.disk_usage(sys.argv[2]).free - int(sys.argv[5]), 0)
    if remaining_bytes > available_bytes:
        raise RuntimeError(
            f"Model needs {remaining_bytes / 1e9:.2f} GB of additional space, "
            f"but only {available_bytes / 1e9:.2f} GB is available after reserving other downloads."
        )
    print(f"__NATIV_PROGRESS__:{cached_bytes}:{total_bytes}", flush=True)
    """
}
