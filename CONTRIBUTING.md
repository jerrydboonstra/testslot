# Contributing to testslot

Thanks for helping. testslot is a small Python package: the entry script `testslot` and the code in `lib/testslot/`, with its tests in `test.sh`.

- Run the tests from this folder: `bash test.sh ./testslot`. They need python3 and flock, use no network, sudo, ssh or git, and take a few minutes.
- Send a change as a pull request against `main`. Keep it small, and add or change a case in `test.sh` that fails without your change.
- A bug report or an idea goes in an issue; use the forms.
- A security problem goes through private reporting, not an issue: see SECURITY.md.
- By contributing you agree your change is under the MIT licence in LICENSE.
- The interface is the docstring at the top of `lib/testslot/cli.py`; README.md says what each file is for.
