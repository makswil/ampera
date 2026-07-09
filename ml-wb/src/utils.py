"""Device resolution and error handling."""

import logging
import sys
import torch


def setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(
        format="%(levelname)s: %(message)s",
        level=logging.DEBUG if verbose else logging.WARNING,
        stream=sys.stderr,
    )


class WBError(RuntimeError):
    def __init__(self, message: str, exit_code: int = 1):
        super().__init__(message)
        self.exit_code = exit_code

    def __str__(self) -> str:
        return f"[white-balance error] {self.args[0]}"


def get_device(spec: str = "auto") -> torch.device:
    """Resolve a device spec ("auto"/"cuda"/"mps"/"cpu") to a torch.device."""
    if spec == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda")
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")

    known = {"cuda", "mps", "cpu"}
    if spec not in known:
        raise WBError(f"Unknown device '{spec}'. Valid: {', '.join(sorted(known))} or 'auto'.")
    return torch.device(spec)
