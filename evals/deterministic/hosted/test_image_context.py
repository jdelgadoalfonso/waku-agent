"""DETERMINISTIC EVAL -- the two build contexts are allowlists, and what they
admit.

THIS IS A DRIFT CHECK, NOT THE GUARD. It reads two .dockerignore files as
text. The guard that a secret does not enter the image is
evals/hosted_docker/test_image.py::
test_a_secret_planted_inside_an_admitted_tree_stays_out_of_the_image, which
plants a secret-shaped file inside an admitted tree, builds, and looks -- the
only test in this task that fails if the ignore file is deleted, since the
tenant Dockerfile COPYs named paths and its /app listing does not change.
test_the_tenant_image_holds_what_it_copies_and_nothing_more, in the same file,
is the guard on the COPY list. A test that reads the exclude
config instead of the artefact is the defect this spec has found five times,
most recently as "a packaging test asserting an exclude string instead of the
built artefact"; naming which of the two this is, in the file itself, is how
the next reader knows not to trust it alone.

What it is FOR: the Docker tier needs a daemon and does not run in `make gate`
or on a contributor's PR. This one runs everywhere, offline, in under a
millisecond, and catches the one mistake that is easy to make and expensive to
find later -- adding a deny line (`.env`) to a file whose whole design is
allow lines, which reads as tightening and is in fact loosening, because the
next secret is not called .env.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
IMAGE = ROOT / "hosted" / "image"

# Spec, "Images": "The tenant image admits only waku/, skills/, pyproject.toml,
# uv.lock, README.md and the license files" -- the two license files being the
# ones pyproject.toml's license-files names at the repo root. "The services
# image admits hosted/, pyproject.toml, uv.lock and the license files".
#
# data/ joined the tenant list on 2026-11-01, and it is not documentation:
# pyproject.toml force-includes data/providers.toml and data/static into the
# wheel, and the tenant image is the one that builds it. THIS TABLE PINS
# TODAY'S ANSWER AND THAT IS ALL IT DOES -- it asserted the stale list while
# the build could not have succeeded, so
# test_every_force_include_is_admitted_by_the_image_that_builds_it below
# derives the requirement from pyproject.toml instead.
ADMITTED = {
    "tenant.Dockerfile.dockerignore": {
        "waku/", "skills/", "data/", "pyproject.toml", "uv.lock", "README.md",
        "LICENSE", "LICENSE-BRAND",
    },
    "services.Dockerfile.dockerignore": {
        "hosted/", "pyproject.toml", "uv.lock", "LICENSE", "LICENSE-BRAND",
    },
}

# The re-exclusions that reach INSIDE the admitted trees, in the order they
# must appear. Order is not decoration: Docker is last-match-wins, so a
# re-exclusion above the `!` line that admits its tree is re-admitted by that
# line and does nothing at all. A review defeated the first version of this
# file twice with all four tests green -- once by moving these lines above the
# admissions, once by deleting them -- so the sequence is pinned here, not
# just the membership.
#
# `**/.*` IS THE ONE THAT MATTERS, and it replaced a list of four named
# shapes (`**/.env`, `**/.env.*` and two cache directories). The named list
# was a denylist: a second review planted `.netrc` and `.aws` beside them and
# walked straight through. `**/.*` refuses every dotfile inside an admitted
# tree, including the ones nobody has thought of, and it costs nothing --
# `git ls-files waku skills` lists no dotfile at all, and `hosted/` has
# exactly one, a .gitkeep placeholder that carries nothing.
#
# IT IS NOT A CLOSED CLASS, AND THE FILES SAY SO. A secret whose name is not
# dot-prefixed and does not end .pem or .key -- credentials.json, id_rsa,
# server.p12 -- still enters the context and the image. No pattern can tell a
# secret from a config file by its name, and the allowlist version of this
# rule does not exist, because the trees themselves are what is admitted. So
# this is the strongest available rule plus a stated limit, and
# evals/hosted_docker/test_image.py::
# test_a_secret_planted_inside_an_admitted_tree_stays_out_of_the_image plants
# both classes and pins which ones get through.
RE_EXCLUDED_INSIDE = (
    "**/__pycache__/",
    "**/*.pyc",
    "**/.*",
    "**/*.pem",
    "**/*.key",
)


def _lines(name: str) -> list[str]:
    """The file's rules, as this drift check reads them.

    NOT BYTE-FOR-BYTE MOBY'S PARSER, and the difference is worth knowing.
    moby's dockerignore reader tests for a leading `#` BEFORE trimming
    whitespace; this trims first. So a line written `   # !waku/` is a comment
    here and a PATTERN to Docker -- the literal pattern `# !waku/` after its
    own trim, which matches a file by that name and therefore nothing.

    That divergence is the safe direction and only the safe direction: it can
    make this parser see FEWER rules than Docker does, and every rule it can
    miss that way is an inert one. It cannot make this parser see an admission
    or an exclusion that Docker does not honour. If moby ever trims first, the
    two agree and nothing here changes.
    """
    text = (IMAGE / name).read_text(encoding="utf-8")
    return [line.strip() for line in text.splitlines()
            if line.strip() and not line.strip().startswith("#")]


def test_both_ignore_files_exclude_everything_first():
    """An allowlist starts by refusing everything. If `*` is not the first
    rule, every later `!` line is decoration: the default is already admit."""
    for name in ADMITTED:
        lines = _lines(name)
        assert lines[0] == "*", (
            f"{name} does not begin with `*`, so it is not an allowlist and its "
            f"`!` lines admit nothing that was not already admitted. First "
            f"line: {lines[0]!r}")
        assert ".*" in lines[:2], (
            f"{name} must also exclude `.*`. Docker's matcher is not a shell "
            "glob and `*` is documented to match dot-prefixed names, but the "
            "file that keeps .env out of an image should not rest on that.")


def test_the_admitted_set_is_the_specs_set():
    for name, expected in ADMITTED.items():
        admitted = {line[1:] for line in _lines(name) if line.startswith("!")}
        assert admitted == expected, (
            f"{name} admits {sorted(admitted)}, the spec says {sorted(expected)}.\n"
            "Widening this is a spec change, not a build fix.")


def test_neither_image_can_see_the_other_side():
    """The half of the waku/ <-> hosted/ boundary that
    evals/deterministic/test_hosted_boundary.py names as out of its reach --
    its docstring says a Dockerfile 'can run `python -c "import waku..."` with
    nothing here to stop them'.

    It is closed here by the CONTEXT, not by forbidding a line: with waku/
    outside the services image's context, such a RUN fails the build loudly.
    """
    tenant = {line[1:] for line in _lines("tenant.Dockerfile.dockerignore")
              if line.startswith("!")}
    services = {line[1:] for line in _lines("services.Dockerfile.dockerignore")
                if line.startswith("!")}
    assert "hosted/" not in tenant, "the tenant image's context admits hosted/"
    assert "waku/" not in services, "the services image's context admits waku/"


def test_the_re_exclusions_follow_the_admissions_and_are_all_there():
    """Docker is LAST-MATCH-WINS, so a `**/` re-exclusion only re-excludes
    anything if it comes after the `!` line that admitted its tree.

    Both halves are load-bearing, and a review proved it by defeating the
    earlier version of this file twice while every test stayed green:

      move the four `**/` lines above the seven `!` lines -> __pycache__,
      *.pyc, .pytest_cache and .ruff_cache are re-admitted into the image, and
      `ls -a /app` does not change, so the Docker tests stay green too

      delete the four `**/` lines -> the same effect, one fewer edit

    So this pins the sequence AND the exact list. Adding a re-exclusion is a
    one-line change here; moving one is not a change anybody makes by accident.
    """
    for name in ADMITTED:
        lines = _lines(name)[2:]
        admissions = [i for i, line in enumerate(lines) if line.startswith("!")]
        re_exclusions = [i for i, line in enumerate(lines) if line.startswith("**/")]
        assert admissions, f"{name} admits nothing"
        assert re_exclusions, (
            f"{name} re-excludes nothing inside the trees it admits. The four "
            "build-noise lines and the four secret lines are not decoration: "
            "without them __pycache__ and a planted waku/.env ride into the "
            "image inside an admitted tree.")
        assert min(re_exclusions) > max(admissions), (
            f"{name} has a `**/` re-exclusion at line {min(re_exclusions) + 3} "
            f"before its last `!` admission at line {max(admissions) + 3}. "
            "Docker is last-match-wins, so that admission re-admits everything "
            "the re-exclusion just excluded, and the re-exclusion does nothing.")
        found = tuple(lines[i] for i in re_exclusions)
        assert found == RE_EXCLUDED_INSIDE, (
            f"{name} re-excludes {list(found)}, this file expects "
            f"{list(RE_EXCLUDED_INSIDE)}.\n"
            "Dropping one of these re-admits it into an admitted tree; the "
            "four secret patterns are the ones that matter.")


def test_no_deny_line_hides_among_the_allow_lines():
    """After `*` and `.*`, every line is either an admission (`!...`) or a
    re-exclusion INSIDE an admitted tree (`**/...`). A bare `xyz` line -- the
    natural shape of `.env` added by somebody being careful -- is neither, and
    it is how an allowlist turns back into a denylist one line at a time."""
    for name in ADMITTED:
        stray = [line for line in _lines(name)[2:]
                 if not line.startswith("!") and not line.startswith("**/")]
        assert not stray, (
            f"{name} has deny lines among the allow lines: {stray}\n"
            "This file excludes everything already. Naming one more thing to "
            "exclude does nothing, and it teaches the next reader that the "
            "file is a denylist, which is when a secret gets in.")


def test_the_context_probes_leftovers_cannot_be_committed():
    """The Docker probe writes files called deploy.pem, deploy.key, id_rsa and
    .aws/credentials into the checkout of a public repository, and deletes them
    in a `finally`. This is about the run that never reaches the finally.

    Without a .gitignore line, the next `git add -A` stages two files named
    like real private keys and nobody reads that diff twice. `git check-ignore`
    reported exactly one of the twelve as ignored before this test existed
    (`.env`, and only because `.env` is ignored everywhere).

    IT ASKS THE FIXTURE, NOT A COPY OF ITS LIST. The names come from
    evals/hosted_docker/test_image.py's own constants, so a name added to the
    probe and not to .gitignore fails here rather than waiting for the crash
    that leaves it behind. `git check-ignore` is the authority, not a pattern
    this test re-implements.
    """
    sys.path.insert(0, str(ROOT / "evals" / "hosted_docker"))
    import test_image  # noqa: E402  -- the probe's own source of truth

    planted = [test_image.CONTEXT_PROBE_KEPT,
               *test_image.CONTEXT_PROBE_REFUSED,
               *test_image.CONTEXT_PROBE_GETS_THROUGH,
               ".aws/credentials"]

    not_ignored = []
    for name in planted:
        path = test_image.CONTEXT_PROBE_DIR / name
        proc = subprocess.run(["git", "check-ignore", "-q", str(path)],
                              cwd=ROOT, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            not_ignored.append(str(path))

    assert not not_ignored, (
        f"the context probe plants these where git would offer to commit them: "
        f"{not_ignored}\n"
        "Add a .gitignore line covering waku/_c1_context_probe/ -- one line "
        "covers every name, including the ones nobody has added yet -- rather "
        "than listing the new file. Files named deploy.pem and id_rsa reaching "
        "a public repository is not a tidiness problem.")


# --- what the build NEEDS, derived rather than listed ------------------------

def _force_includes() -> dict[str, str]:
    """Every path `pyproject.toml` copies into the wheel, and where to.

    Read from the build config, never written down here: this is the half of
    the pair that must not be re-listed, because a force-include added next
    month has to arrive at these pins as a new requirement by itself.
    """
    import tomllib

    with (ROOT / "pyproject.toml").open("rb") as fh:
        return tomllib.load(fh)["tool"]["hatch"]["build"]["targets"]["wheel"].get(
            "force-include", {})


def _images_that_build_the_project() -> list[Path]:
    """The Dockerfiles that build waku-agent itself, found by what they DO.

    `uv sync --no-install-project` never reaches the build backend, so the
    services image needs no force-include source and must not be made to admit
    one: its allowlist refusing waku/ is the licence boundary. Found by
    reading the Dockerfiles rather than named here, so a third image that
    installs the project cannot be forgotten.
    """
    found = []
    for dockerfile in sorted(IMAGE.glob("*.Dockerfile")):
        text = dockerfile.read_text(encoding="utf-8")
        if "uv sync" in text and "--no-install-project" not in text:
            found.append(dockerfile)
    return found


def _admissions(name: str) -> set[str]:
    return {line[1:] for line in _lines(name) if line.startswith("!")}


def _admits(admissions: set[str], path: str) -> bool:
    """Whether an allowlist admits `path`.

    A prefix check on the `!` lines, which is all an allowlist does for a
    tree: `!data/` admits `data/providers.toml`, and `!skills/` admits
    `skills`. It does not model moby's glob matcher and does not need to --
    every admission in these files is a literal path or a literal tree, and
    the build below is the authority on the rest.
    """
    wanted = path.strip("/")
    return any(wanted == rule.strip("/") or wanted.startswith(rule.strip("/") + "/")
               for rule in admissions)


def test_every_force_include_is_admitted_by_the_image_that_builds_it():
    """THE INVARIANT. The table above pins today's answer, and on 2026-11-01
    that was not enough: the tenant context refused `data/` while
    pyproject.toml force-included two paths out of it, so every deterministic
    test stayed green and the image build could not have succeeded. This reads
    the OTHER half -- what the build actually needs -- so a force-include added
    tomorrow fails here instead of in a daemon nobody runs on a PR."""
    forced = _force_includes()
    assert forced, (
        "pyproject force-includes nothing — the wheel would ship no skills, no "
        "provider registry and no dashboard frontend")
    images = _images_that_build_the_project()
    assert images, (
        "no Dockerfile installs the project, so this pin checks nothing: the "
        "`uv sync` line it looks for has moved or been renamed")
    for dockerfile in images:
        ignore = dockerfile.with_name(dockerfile.name + ".dockerignore")
        assert ignore.is_file(), f"{ignore.name} is missing, so the context is the whole checkout"
        admissions = _admissions(ignore.name)
        for source in forced:
            assert _admits(admissions, source), (
                f"{dockerfile.name}'s context refuses {source!r}, and pyproject.toml "
                f"force-includes it into the wheel — the build fails with "
                f"`Forced include not found: {source}`.\n"
                f"Admit it in {ignore.name}: a force-include source is part of what "
                "the image is built FROM, not a detail of the wheel.")


def test_a_context_of_only_the_admitted_paths_still_builds_the_wheel(tmp_path):
    """The failure, reproduced and turned green, without a daemon.

    A Docker build sends the daemon exactly the admitted paths, so this copies
    exactly those into a scratch directory, builds the wheel there with the
    backend the project already pins as a dev dependency, and looks inside the
    result. Remove `!data/` from the tenant ignore file and this fails with the
    build's own `FileNotFoundError`; add a force-include the context cannot see
    and it fails the same way. That is the Docker tier's failure, on every PR,
    in about a second."""
    import shutil
    import zipfile

    from hatchling.builders.wheel import WheelBuilder

    forced = _force_includes()
    # The `**/` re-exclusions, as the same patterns: a context that carried
    # __pycache__ and dotfiles is not the context the image gets.
    re_excluded = shutil.ignore_patterns("__pycache__", "*.pyc", ".*", "*.pem", "*.key")

    for dockerfile in _images_that_build_the_project():
        ignore = dockerfile.with_name(dockerfile.name + ".dockerignore")
        context = tmp_path / dockerfile.stem
        context.mkdir()
        for rule in sorted(_admissions(ignore.name)):
            source = ROOT / rule.strip("/")
            assert source.exists(), (
                f"{ignore.name} admits {rule!r}, which is not in the checkout — the "
                "context would be missing a path it claims to send")
            target = context / rule.strip("/")
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target, ignore=re_excluded)
            else:
                shutil.copy2(source, target)

        out = tmp_path / (dockerfile.stem + "-wheel")
        built = list(WheelBuilder(str(context)).build(directory=str(out)))
        assert built, "the wheel build produced no artefact"
        with zipfile.ZipFile(built[0]) as wheel:
            members = set(wheel.namelist())
        for source, destination in forced.items():
            wanted = destination.strip("/")
            assert wanted in members or any(m.startswith(wanted + "/") for m in members), (
                f"the wheel built from {dockerfile.name}'s context carries no "
                f"{destination!r}: {source!r} was not in the context to copy")
