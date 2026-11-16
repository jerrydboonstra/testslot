"""Test helper for test.sh: load the testslot package and hand back one object, `m`, to read and patch names on.

Before the package split the checks loaded the single file and wrote `m.read_cap = lambda: 20`. Now each name lives in one
submodule, so `m.<name>` reads and writes it there. A name that no submodule owns, or that more than one owns, raises:
a typo in a patch must fail the check, not make a new attribute that nothing reads. A standard-library module (`m.time`)
reads through when every submodule that has it holds the same object, and can't be assigned."""
import importlib
import os
import pkgutil
import sys
import types


def load(path):
    """Import every module of the package beside the entry script `path` (a link is followed) and return the shim."""
    lib = os.path.join(os.path.dirname(os.path.realpath(path)), "lib")
    sys.dont_write_bytecode = True  # as the entry script does: the checks leave no __pycache__ in the tree
    sys.path.insert(0, lib)
    names = sorted(i.name for i in pkgutil.iter_modules([os.path.join(lib, "testslot")]))
    return _Shim([importlib.import_module("testslot." + n) for n in names])


class _Shim(object):
    def __init__(self, mods):
        object.__setattr__(self, "_mods", mods)

    def _owners(self, name):
        return [mod for mod in object.__getattribute__(self, "_mods") if name in vars(mod)]

    def __getattr__(self, name):
        owners = self._owners(name)
        if not owners:
            raise AttributeError("no testslot module defines %r" % name)
        values = [vars(mod)[name] for mod in owners]
        if len(owners) > 1:
            if all(isinstance(v, types.ModuleType) and v is values[0] for v in values):
                return values[0]
            raise AttributeError("%r is defined in more than one testslot module: %s" % (name, ", ".join(mod.__name__ for mod in owners)))
        return values[0]

    def __setattr__(self, name, value):
        owners = self._owners(name)
        if len(owners) != 1 or isinstance(vars(owners[0])[name], types.ModuleType):
            raise AttributeError("cannot set %r: %d testslot modules define it (it must be exactly one, and not a module)" % (name, len(owners)))
        setattr(owners[0], name, value)
