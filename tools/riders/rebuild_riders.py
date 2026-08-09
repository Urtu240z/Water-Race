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
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".tga", ".bmp"}


class RebuildError(RuntimeError):
    pass


def godot_path(cli: str | None) -> Path:
    explicit = cli or os.environ.get("GODOT_BIN")
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise RebuildError(
                f"Godot executable not found: {path}. Set GODOT_BIN or use --godot-bin."
            )
    else:
        path = next(
            (Path(found) for name in (
                "godot",
                "godot4",
                "Godot_v4.7.1-stable_win64_console.exe",
                "Godot_v4.7.1-stable_win64.exe",
            ) if (found := shutil.which(name))),
            None,
        )
        if path is None:
            raise RebuildError("Godot 4.7.1 was not found. Set GODOT_BIN or use --godot-bin.")
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
    rider_profile = profile["riders"][rider]
    imported_scene = f"res://.godot/imported/{rider}_compatible.glb-{rider_profile['import_cache']}.scn"
    lines = [
        "[remap]", "", 'importer="scene"', "importer_version=1", 'type="PackedScene"',
        f'uid="{rider_profile["uid"]}"', f'path="{imported_scene}"', "", "[deps]", "",
        f'source_file="{source}"', f'dest_files=["{imported_scene}"]', "", "[params]", "",
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


def candidate_dir(rider: str) -> Path:
    return rider_dir(rider) / "runtime" / ".rebuild_output"


def candidate_texture_dir(rider: str) -> Path:
    # Godot intentionally skips dot-prefixed directories during filesystem import.
    return rider_dir(rider) / "runtime" / "rebuild_candidate" / "textures"


def copy_candidate_textures(rider: str) -> int:
    candidate = candidate_dir(rider)
    if candidate.exists():
        shutil.rmtree(candidate)
    textures = candidate_texture_dir(rider)
    if textures.parent.exists():
        shutil.rmtree(textures.parent)
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
    textures = f"res://gameplay/riders/{rider}/runtime/rebuild_candidate/textures"
    run_godot(godot, ["--script", "res://dev/extraction/riders/extract_rider_skin.gd", "--", "--rider", rider, "--output-dir", output, "--texture-root", textures], f"{rider} extraction")
    run_godot(godot, ["--script", "res://dev/tests/riders/validate_rider_rebuild_candidate.gd", "--", "--rider", rider, "--runtime-root", output, "--texture-root", textures], f"{rider} candidate resource validation")


def retarget_texture_imports(rider: str, texture_directory: Path) -> None:
    temporary_root = f"res://gameplay/riders/{rider}/runtime/rebuild_candidate/textures/"
    runtime_root = f"res://gameplay/riders/{rider}/runtime/textures/"
    for sidecar in texture_directory.glob("*.import"):
        sidecar.write_text(sidecar.read_text(encoding="utf-8").replace(temporary_root, runtime_root), encoding="utf-8")


def publish_candidates(godot: Path, riders: tuple[str, ...]) -> None:
    previous_texture_directories: list[Path] = []
    for rider in riders:
        runtime = rider_dir(rider) / "runtime"
        textures = runtime / "textures"
        previous_textures = runtime / ".rebuild_previous_textures"
        if previous_textures.exists():
            raise RebuildError(f"{rider}: previous transactional texture directory is still present.")
        if textures.exists():
            os.replace(textures, previous_textures)
            previous_texture_directories.append(previous_textures)
        shutil.copytree(candidate_texture_dir(rider), textures)
        retarget_texture_imports(rider, textures)
    for rider in riders:
        candidate_root = f"res://gameplay/riders/{rider}/runtime/.rebuild_output"
        runtime_textures = f"res://gameplay/riders/{rider}/runtime/textures"
        run_godot(godot, ["--script", "res://dev/extraction/riders/retarget_rider_rebuild_candidate.gd", "--", "--rider", rider, "--runtime-root", candidate_root, "--texture-root", runtime_textures], f"{rider} candidate texture retarget")
        run_godot(godot, ["--script", "res://dev/tests/riders/validate_rider_rebuild_candidate.gd", "--", "--rider", rider, "--runtime-root", candidate_root, "--texture-root", runtime_textures], f"{rider} retargeted candidate validation")
    for rider in riders:
        runtime = rider_dir(rider) / "runtime"
        candidate = candidate_dir(rider)
        for name in (f"{rider}_body_mesh.res", f"{rider}_skin.res"):
            os.replace(candidate / name, runtime / name)
        candidate.rmdir()
        shutil.rmtree(candidate_texture_dir(rider).parent)
    for previous_textures in previous_texture_directories:
        shutil.rmtree(previous_textures)


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
        runtime = rider_dir(rider) / "runtime"
        for temporary in (".rebuild_output", ".rebuild_previous_textures", "rebuild_candidate"):
            if (runtime / temporary).exists():
                leftovers.append(str((runtime / temporary).relative_to(ROOT)))
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
                    copied = copy_candidate_textures(rider)
                    print(f"CANDIDATE_TEXTURE_COPY=PASS rider={rider} count={copied}")
                import_project(godot)
                for rider in riders:
                    check_candidate(godot, rider)
                publish_candidates(godot, riders)
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
                copied = copy_candidate_textures(rider)
                print(f"CANDIDATE_TEXTURE_COPY=PASS rider={rider} count={copied}")
            import_project(godot)
            for rider in riders:
                check_candidate(godot, rider)
            publish_candidates(godot, riders)
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
