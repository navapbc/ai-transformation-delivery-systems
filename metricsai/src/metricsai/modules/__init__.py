"""Module registry.

Built-in modules register themselves on import via :func:`register`. The CLI runs every
registered module by default, or the subset named with ``--module``.
"""

from __future__ import annotations

from metricsai.modules.base import MetricsModule

#: All registered modules, keyed by ``MetricsModule.name``.
REGISTRY: dict[str, MetricsModule] = {}


def register(module: MetricsModule) -> MetricsModule:
    """Add ``module`` to :data:`REGISTRY`.

    :param module: The module instance to register.
    :returns: The same instance, so this can be used as a decorator on a subclass.
    :raises ValueError: If a module with the same name is already registered.
    """
    if module.name in REGISTRY:
        raise ValueError(f"Duplicate module name: {module.name!r}")
    REGISTRY[module.name] = module
    return module


def selected_modules(names: list[str] | None) -> list[MetricsModule]:
    """Return the modules to run for this invocation.

    :param names: Explicit module names from ``--module``. When empty or ``None``, every
        registered module is returned (sorted by name for stable output).
    :returns: The selected module instances.
    :raises KeyError: If any requested name is not registered.
    """
    if not names:
        return [REGISTRY[name] for name in sorted(REGISTRY)]

    unknown = [name for name in names if name not in REGISTRY]
    if unknown:
        available = ", ".join(sorted(REGISTRY)) or "(none)"
        raise KeyError(f"Unknown module(s): {', '.join(unknown)}. Available: {available}")
    return [REGISTRY[name] for name in names]


# Import built-in modules for their registration side effects.
from metricsai.modules import build_pr as _build_pr  # noqa: E402,F401
from metricsai.modules import security as _security  # noqa: E402,F401
from metricsai.modules import testing as _testing  # noqa: E402,F401
