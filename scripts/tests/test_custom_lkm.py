"""Exercise packaging guards with a synthetic arm64 ELF, not a real kernel build."""

import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RELEASE = "5.15.220-g7ec40be85325"


class CustomModuleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rkx-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.src = self.root / "kernel"
        self.out = self.root / "out"
        self.tools = self.root / "tools"
        self.clang = self.root / "clang"
        for path in (
            self.src / "drivers/android",
            self.out / "include/generated",
            self.out / "kernel",
            self.tools,
            self.clang,
        ):
            path.mkdir(parents=True)
        for tool in ("clang", "llvm-nm", "llvm-strip"):
            executable = shutil.which(tool)
            if not executable:
                self.skipTest(f"Missing {tool}")
            (self.clang / tool).symlink_to(executable)
        # Kbuild is mocked below and the fixture is compiled without linking.
        # The packaging test therefore needs only an executable linker placeholder.
        (self.clang / "ld.lld").symlink_to(shutil.which("true"))
        (self.src / "drivers/android/binder_internal.h").touch()
        self.config = self.out / ".config"
        self.config.write_text("""CONFIG_MODULES=y
CONFIG_MODVERSIONS=y
CONFIG_ANDROID_VENDOR_HOOKS=y
CONFIG_KPROBES=y
CONFIG_CFI_CLANG=y
CONFIG_MODULE_SIG_PROTECT=y
# CONFIG_MODULE_SIG_FORCE is not set
""")
        banner = subprocess.check_output(
            [str(self.clang / "clang"), "--version"], text=True
        ).splitlines()[0]
        (self.out / "include/generated/compile.h").write_text(
            f'#define LINUX_COMPILER "{banner}"\n'
        )
        (self.out / "vmlinux").write_bytes(b"fixture only")
        self.symvers = self.out / "vmlinux.symvers"
        self.symvers.write_text(
            "0x12345678\ttarget_export\tvmlinux\tEXPORT_SYMBOL\n0x87654321\tmodule_layout\tvmlinux\tEXPORT_SYMBOL\n"
        )
        self.protected = self.out / "kernel/gki_module_protected.h"
        self.protected.write_text("static const char *symbols[] = {};\n")
        source = self.root / "fixture.c"
        source.write_text(f"""
extern int target_export(void);
int (*reference)(void) = target_export;
void __cfi_check(void) {{}}
const char modinfo[] __attribute__((section(".modinfo"), used)) = "vermagic={RELEASE} SMP preempt mod_unload modversions aarch64\\0license=GPL";
struct version {{ unsigned long crc; char name[56]; }};
const struct version versions[] __attribute__((section("__versions"), used)) = {{
    {{0x12345678, "target_export"}}, {{0x87654321, "module_layout"}}
}};
""")
        self.ko = self.root / "fixture.ko"
        subprocess.run(
            [
                str(self.clang / "clang"),
                "--target=aarch64-linux-gnu",
                "-fno-pic",
                "-c",
                str(source),
                "-o",
                str(self.ko),
            ],
            check=True,
        )
        make = self.tools / "make"
        make.write_text("""#!/bin/bash
set -eu
for arg in "$@"; do
  case "$arg" in
    M=*) module_dir=${arg#M=} ;;
    kernelrelease) printf '%s\\n' "$FIXTURE_RELEASE"; exit 0 ;;
    modules_prepare)
      if [[ ${MUTATE_CONFIG:-0} = 1 ]]; then echo CONFIG_CHANGED=y >> "$FIXTURE_CONFIG"; fi
      exit 0 ;;
    modules) cp "$FIXTURE_KO" "$module_dir/rekernel_x.ko"; exit 0 ;;
  esac
done
""")
        make.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=f"{self.tools}:{os.environ['PATH']}",
            EXPECTED_KERNEL_RELEASE=RELEASE,
            FIXTURE_RELEASE=RELEASE,
            FIXTURE_KO=str(self.ko),
            FIXTURE_CONFIG=str(self.config),
        )
        self.dest = self.root / "packages"

    def build(self):
        return subprocess.run(
            [
                "bash",
                str(REPO / "scripts/build-custom-lkm.sh"),
                str(self.src),
                str(self.out),
                str(self.clang),
                str(self.dest),
            ],
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    def rejected(self, message):
        result = self.build()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stdout)
        self.assertFalse(list(self.dest.glob("*.zip")))

    def test_package_contains_exact_release_and_loader(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout)
        with zipfile.ZipFile(next(self.dest.glob("*.zip"))) as archive:
            self.assertEqual(archive.read("kernel-release").decode().strip(), RELEASE)
            self.assertIn("post-fs-data.sh", archive.namelist())
            self.assertIn("rekernel_x.ko", archive.namelist())
            self.assertIn("config_sha256=", archive.read("build-info.txt").decode())
            self.assertNotIn("updateJson=", archive.read("module.prop").decode())
        self.assertFalse(list(self.dest.glob(".rkx-build.*")))

    def test_reject_kernel_release_mismatch(self):
        self.env["FIXTURE_RELEASE"] = "5.15.220-other"
        self.rejected("expected " + RELEASE)

    def test_reject_missing_symbol_crcs(self):
        self.symvers.unlink()
        self.rejected("No target symbol CRCs")

    def test_reject_symbol_crc_mismatch(self):
        self.symvers.write_text(
            self.symvers.read_text().replace("12345678", "11111111")
        )
        self.rejected("mismatched target CRC for target_export")

    def test_reject_protected_import(self):
        self.protected.write_text('static const char *symbols[] = {"target_export"};\n')
        self.rejected("needs protected symbols: target_export")

    def test_reject_forced_signatures(self):
        self.config.write_text(self.config.read_text() + "CONFIG_MODULE_SIG_FORCE=y\n")
        self.rejected("requires trusted module signatures")

    def test_reject_config_drift_during_prepare(self):
        self.env["MUTATE_CONFIG"] = "1"
        self.rejected("preparation changed the original configuration")

    def test_reject_wrong_compiler(self):
        (self.out / "include/generated/compile.h").write_text('"some other compiler"\n')
        self.rejected("Clang differs")


class LoaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rkx-loader-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / "bin"
        self.tools.mkdir()
        self.module = self.root / "module"
        self.module.mkdir()
        shutil.copy(REPO / "template-custom/post-fs-data.sh", self.module)
        (self.module / "kernel-release").write_text(RELEASE + "\n")
        for name, body in {
            "uname": 'printf "%s\\n" "$FIXTURE_RELEASE"',
            "insmod": 'touch "$INS_MOD_MARKER"; echo "fixture load error"; exit "${INS_MOD_STATUS:-0}"',
            "dmesg": 'echo "rekernel_x: fixture kernel diagnostic"',
        }.items():
            path = self.tools / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        self.marker = self.root / "insmod-called"
        self.env = dict(
            os.environ,
            PATH=f"{self.tools}:{os.environ['PATH']}",
            FIXTURE_RELEASE=RELEASE,
            INS_MOD_MARKER=str(self.marker),
        )

    def run_loader(self):
        return subprocess.run(
            ["sh", str(self.module / "post-fs-data.sh")],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def test_load_failure_is_logged_and_boot_marker_cleared(self):
        self.env["INS_MOD_STATUS"] = "7"
        result = self.run_loader()
        self.assertEqual(result.returncode, 7)
        log = (self.module / "load.log").read_text()
        self.assertIn("fixture load error", log)
        self.assertIn("exit=7", log)
        self.assertIn("fixture kernel diagnostic", log)
        self.assertFalse((self.module / ".boot").exists())

    def test_kernel_change_disables_before_loading(self):
        self.env["FIXTURE_RELEASE"] = "5.15.220-other"
        self.assertNotEqual(self.run_loader().returncode, 0)
        self.assertTrue((self.module / "disable").exists())
        self.assertFalse(self.marker.exists())

    def test_interrupted_load_disables_before_retrying(self):
        (self.module / ".boot").touch()
        self.assertNotEqual(self.run_loader().returncode, 0)
        self.assertTrue((self.module / "disable").exists())
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
