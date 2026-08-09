#!/usr/bin/env python3
"""Rebuild runtime Rider resources from out-of-game compatible GLB inputs.

The GLB only exists in game/ while Godot's ResourceImporterScene is running.
Runtime files are backed up and replaced only after every candidate is valid.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "game"
PROFILE = Path(__file__).with_name("import_profiles.json")
RIDERS = ("rider_01", "rider_02", "rider_03", "rider_04")
GODOT_DEFAULT = Path(r"C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64_console.exe")
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".tga", ".bmp"}


class RebuildError(RuntimeError):
    pass


def godot_path(cli: str | None) -> Path:
    candidate = cli or os.environ.get("GODOT_BIN") or str(GODOT_DEFAULT)
    path = Path(candidate)
    if not path.is_file():
        raise RebuildError(f"Godot 4.7.1 executable not found: {path}")
    output = subprocess.run([str(path), "--version"], capture_output=True, text=True, check=False)
    version = (output.stdout or output.stderr).strip()
    if output.returncode != 0 or not version.startswith("4.7.1"):
        raise RebuildError(f"Godot 4.7.1 is required; found: {version or 'unavailable'}")
    print(f"Godot version gate: PASS ({version})")
    return path


def run_godot(godot: Path, args: list[str], label: str) -> None:
    command = [str(godot), "--headless", "--path", str(GAME), *args]
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr)
    if result.returncode != 0:
        raise RebuildError(f"{label} failed with exit code {result.returncode}.")


def variant(value: object) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, dict) and not value:
        return "{}"
    return str(value)


def write_stage_import(rider: str, profile: dict) -> None:
    target = stage_glb(rider).with_suffix(".glb.import")
    source = f"res://gameplay/riders/{rider}/{rider}_compatible.glb"
    lines = [
        "[remap]", "", 'importer="scene"', "importer_version=1", 'type="PackedScene"',
        f'uid="{profile["riders"][rider]["uid"]}"', "", "[deps]", "",
        f'source_file="{source}"', "", "[params]", "",
    ]
    lines.extend(f"{key}={variant(value)}" for key, value in profile["scene_params"].items())
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")


def rider_dir(rider: str) -> Path:
    return GAME / "gameplay" / "riders" / rider


def stage_glb(rider: str) -> Path:
    return rider_dir(rider) / f"{rider}_compatible.glb"


def source_glb(rider: str) -> Path:
    return ROOT / "source" / "riders" / rider / "compatible" / f"{rider}_compatible.glb"


def source_textures(rider: str) -> list[Path]:
    directory = source_glb(rider).parent / "textures"
    return [path for path in directory.iterdir() if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES] if directory.is_dir() else []


def stage_build_inputs(rider: str, profile: dict) -> None:
    shutil.copy2(source_glb(rider), stage_glb(rider))
    textures = source_textures(rider)
    if not textures:
        raise RebuildError(f"{rider}: no compatible source textures were found beside the build input.")
    for texture in textures:
        shutil.copy2(texture, rider_dir(rider) / texture.name)
    write_stage_import(rider, profile)


def stage_artifacts(rider: str) -> list[Path]:
    directory = rider_dir(rider)
    prefix = f"{rider}_compatible"
    return [path for path in directory.iterdir() if path.is_file() and path.name.startswith(prefix)]


def clear_stage(rider: str) -> None:
    for path in stage_artifacts(rider):
        path.unlink()


def backup_rider(rider: str, backup: Path) -> None:
    source_runtime = rider_dir(rider) / "runtime"
    target_runtime = backup / rider / "runtime"
    if source_runtime.exists():
        shutil.copytree(source_runtime, target_runtime)
    stage_backup = backup / rider / "stage"
    stage_backup.mkdir(parents=True, exist_ok=True)
    for path in stage_artifacts(rider):
        shutil.copy2(path, stage_backup / path.name)


def restore_rider(rider: str, backup: Path) -> None:
    runtime = rider_dir(rider) / "runtime"
    backup_runtime = backup / rider / "runtime"
    if runtime.exists():
        shutil.rmtree(runtime)
    if backup_runtime.exists():
        shutil.copytree(backup_runtime, runtime)
    clear_stage(rider)
    for path in (backup / rider / "stage").glob("*"):
        shutil.copy2(path, rider_dir(rider) / path.name)


def import_project(godot: Path) -> None:
    # --import runs the real editor importer but avoids paying for editor layout/UI startup.
    run_godot(godot, ["--import"], "Godot import pass")


def copy_runtime_textures(rider: str) -> int:
    textures = rider_dir(rider) / "runtime" / "textures"
    textures.mkdir(parents=True, exist_ok=True)
    count = 0
    for source in stage_artifacts(rider):
        if source.suffix.lower() not in IMAGE_SUFFIXES:
            continue
        shutil.copy2(source, textures / source.name)
        count += 1
    if count == 0:
        raise RebuildError(f"{rider}: staged importer did not extract any embedded images.")
    return count


def check_candidate(godot: Path, rider: str) -> None:
    output = f"res://gameplay/riders/{rider}/runtime/.rebuild_output"
    textures = f"res://gameplay/riders/{rider}/runtime/textures"
    run_godot(godot, ["--script", "res://dev/extraction/riders/extract_rider_skin.gd", "--", "--rider", rider, "--output-dir", output, "--texture-root", textures], f"{rider} extraction")
    candidate = rider_dir(rider) / "runtime" / ".rebuild_output"
    for name in (f"{rider}_body_mesh.res", f"{rider}_skin.res"):
        if not (candidate / name).is_file():
            raise RebuildError(f"{rider}: extractor did not create candidate {name}.")


def publish_candidates(riders: tuple[str, ...]) -> None:
    for rider in riders:
        runtime = rider_dir(rider) / "runtime"
        candidate = runtime / ".rebuild_output"
        for name in (f"{rider}_body_mesh.res", f"{rider}_skin.res"):
            os.replace(candidate / name, runtime / name)
        candidate.rmdir()


def normal_validation(godot: Path) -> None:
    for script in (
        "res://dev/tests/riders/validate_rider_identity_migration.gd",
        "res://dev/tests/riders/validate_rider_runtime_resources.gd",
        "res://dev/tests/riders/validate_rider_01_integration.gd",
        "res://dev/tests/riders/validate_rider_04_integration.gd",
        "res://dev/tests/camera/validate_chase_camera_modes.gd",
    ):
        run_godot(godot, ["--script", script], f"normal validation {script}")
    # This validator is a scene with required RiderRig and PauseMenu children, not a bare script.
    run_godot(
        godot,
        ["res://dev/tests/riders/rider_selector_validation.tscn"],
        "normal validation rider selector scene",
    )


def assert_normal_state(riders: tuple[str, ...]) -> None:
    leftovers: list[str] = []
    for rider in riders:
        leftovers.extend(str(path.relative_to(ROOT)) for path in stage_artifacts(rider))
    if leftovers:
        raise RebuildError("Staging artifacts remain: " + ", ".join(leftovers))
    print("NORMAL_STATE=PASS (no compatible GLB, generated stage texture, or stage .import in game/)")


def cleanup_only(riders: tuple[str, ...]) -> None:
    for rider in riders:
        clear_stage(rider)
    print("STAGING_CLEANUP=PASS")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--all", action="store_true", help="rebuild the four physical Riders")
    group.add_argument("--rider", choices=RIDERS, help="rebuild one Rider")
    parser.add_argument("--godot-bin", help="Godot 4.7.1 executable (or set GODOT_BIN)")
    parser.add_argument("--cleanup", action="store_true", help="remove stale staging artifacts and exit")
    # Kept for CI-style callers that execute normal validations as a separate step.
    parser.add_argument("--skip-normal-validation", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--phase", choices=("all", "stage", "finalize"), default="all", help=argparse.SUPPRESS)
    args = parser.parse_args()
    riders = (args.rider,) if args.rider else RIDERS
    if args.cleanup:
        cleanup_only(riders)
        return 0
    if not args.all and not args.rider:
        parser.error("choose --all or --rider")
    profile = json.loads(PROFILE.read_text(encoding="utf-8"))
    if profile.get("godot_version") != "4.7.1":
        raise RebuildError("Import profile version is not pinned to Godot 4.7.1.")
    godot = godot_path(args.godot_bin)
    for rider in riders:
        if not source_glb(rider).is_file():
            raise RebuildError(f"Missing build input: {source_glb(rider)}")
    if args.phase == "stage":
        for rider in riders:
            clear_stage(rider)
            stage_build_inputs(rider, profile)
        import_project(godot)
        for rider in riders:
            run_godot(godot, ["--script", "res://dev/tests/riders/validate_staged_rider_import.gd", "--", "--rider", rider], f"{rider} staged LOD validation")
        print("STAGE_PHASE_STATUS=PASS")
        return 0
    if args.phase == "finalize":
        with tempfile.TemporaryDirectory(prefix="water-race-rider-finalize-") as temporary:
            backup = Path(temporary) / "backup"
            for rider in riders:
                if not stage_glb(rider).is_file():
                    raise RebuildError(f"{rider}: stage is absent; run --phase stage first.")
                backup_rider(rider, backup)
            try:
                for rider in riders:
                    copied = copy_runtime_textures(rider)
                    print(f"RUNTIME_TEXTURE_COPY=PASS rider={rider} count={copied}")
                import_project(godot)
                for rider in riders:
                    check_candidate(godot, rider)
                publish_candidates(riders)
                cleanup_only(riders)
                assert_normal_state(riders)
                if not args.skip_normal_validation:
                    normal_validation(godot)
            except Exception:
                for rider in riders:
                    restore_rider(rider, backup)
                raise
        print("FINALIZE_PHASE_STATUS=PASS")
        return 0
    with tempfile.TemporaryDirectory(prefix="water-race-rider-rebuild-") as temporary:
        backup = Path(temporary) / "backup"
        for rider in riders:
            backup_rider(rider, backup)
        try:
            for rider in riders:
                clear_stage(rider)
                stage_build_inputs(rider, profile)
            import_project(godot)
            for rider in riders:
                run_godot(godot, ["--script", "res://dev/tests/riders/validate_staged_rider_import.gd", "--", "--rider", rider], f"{rider} staged LOD validation")
                copied = copy_runtime_textures(rider)
                print(f"RUNTIME_TEXTURE_COPY=PASS rider={rider} count={copied}")
            import_project(godot)
            for rider in riders:
                check_candidate(godot, rider)
            publish_candidates(riders)
            cleanup_only(riders)
            assert_normal_state(riders)
            if not args.skip_normal_validation:
                normal_validation(godot)
        except Exception:
            for rider in riders:
                restore_rider(rider, backup)
            raise
    print("REBUILD_STATUS=PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RebuildError as error:
        print(f"REBUILD_STATUS=FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
