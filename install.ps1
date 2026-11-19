# Pokemon Pokopia (Recompia / pokopia-recomp) installer for Windows (driven by NUP Studio)
param(
    [string]$Nup = "",
    [string]$Dir = "",
    [string]$ShortcutName = "Pokemon Pokopia",
    [string]$IconPath = "",
    [string]$LauncherUiPath = "",
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}
function Say($msg) { Write-Host "[Recompia] $msg" -ForegroundColor Cyan }

if (-not $Nup -or -not (Test-Path -LiteralPath $Nup)) {
    Say "error: missing .nup file: $Nup"
    exit 1
}
if (-not $Dir) {
    $Dir = Join-Path $env:LOCALAPPDATA "Switch2Recomp\Pokemon Pokopia"
}
$Dir = [System.IO.Path]::GetFullPath($Dir)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Say "installing into $Dir"

$source = $PSScriptRoot
$globalMsysInstaller = Join-Path $source "..\..\install_msys2.ps1"
$msysRoot = "C:\msys64"
$clang64Prefix = Join-Path $msysRoot "clang64"
$clang64Bin = Join-Path $clang64Prefix "bin"

if (-not (Test-Path -LiteralPath (Join-Path $clang64Bin "clang.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "clang++.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "cmake.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "ninja.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "python.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\capstone\capstone.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\SDL3\SDL.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\vma\vk_mem_alloc.h"))) {
    if (-not (Test-Path -LiteralPath $globalMsysInstaller)) {
        Say "error: MSYS2 missing and global installer not found: $globalMsysInstaller"
        exit 1
    }
    & $globalMsysInstaller -Msys $msysRoot
    if ($LASTEXITCODE -ne 0) {
        Say "MSYS2 installation cancelled or failed; stopping recompilation."
        exit 1
    }
}

$pyExe = Join-Path $clang64Bin "python.exe"
$cmakeExe = Join-Path $clang64Bin "cmake.exe"
$ninjaExe = Join-Path $clang64Bin "ninja.exe"
foreach ($req in @($pyExe, $cmakeExe, $ninjaExe, (Join-Path $clang64Bin "clang.exe"), (Join-Path $clang64Bin "clang++.exe"))) {
    if (-not (Test-Path -LiteralPath $req)) {
        Say "error: required component missing: $req"
        exit 1
    }
}

$env:PATH = "$clang64Bin;" + $env:PATH
$env:CLANG64_PREFIX = "C:/msys64/clang64"
$env:PYTHONUTF8 = "1"
$env:PYTHONUNBUFFERED = "1"
$env:PYTHON_JIT = "0"

# Pin to E-cores (logical processors 16+) on Intel 13th/14th-gen to avoid P-core boost instability during heavy Python/C++ codegen
$proc = [System.Diagnostics.Process]::GetCurrentProcess()
$jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 16))
try {
    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
    if ($cpuName -match 'Intel.*1[34]\d{3}' -and [Environment]::ProcessorCount -gt 16) {
        $eCoreMask = [int64]0
        for ($c = 16; $c -lt [Math]::Min(63, [Environment]::ProcessorCount); $c++) {
            $eCoreMask = $eCoreMask -bor ([int64]1 -shl $c)
        }
        if ($eCoreMask -gt 0) {
            Say "detected ${cpuName}: pinning codegen & build to E-cores for stability"
            $proc.ProcessorAffinity = [IntPtr]$eCoreMask
            $jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount - 16, 12))
        }
    }
} catch {}

# ---- Global Saves folder (<ParentDir>\Saves\<GameFolderName>) ----
$parentInstallDir = Split-Path -Parent $Dir
$globalSavesRoot = Join-Path $parentInstallDir "Saves"
$globalSaveDir = Join-Path $globalSavesRoot (Split-Path -Leaf $Dir)
New-Item -ItemType Directory -Force -Path $globalSaveDir | Out-Null

$workRoot = Join-Path $Dir "_work"
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- 1. Extract ExeFS & RomFS from .nup ----
$exefsDir = Join-Path $Dir "exefs"
$romfsDir = Join-Path $Dir "romfs"
if (-not (Test-Path -LiteralPath (Join-Path $exefsDir "main")) -or -not (Test-Path -LiteralPath $romfsDir)) {
    Say "extracting ExeFS and RomFS from .nup..."
    $extractTmp = Join-Path $workRoot "extracted"
    if (Test-Path -LiteralPath $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
    $env:PYTHONPATH = (Join-Path $source "tools")
    try {
        & $pyExe -m nup.cli extract $Nup $extractTmp
        if ($LASTEXITCODE -ne 0) { Say "nup extract failed"; exit 1 }
    } finally {
        Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue
    }

    $foundExefs = Get-ChildItem -LiteralPath $extractTmp -Recurse -Directory -Filter "exefs" | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "main") } | Select-Object -Last 1
    $foundRomfs = Get-ChildItem -LiteralPath $extractTmp -Recurse -Directory -Filter "romfs" | Select-Object -Last 1
    if (-not $foundExefs -or -not $foundRomfs) {
        Say "error: exefs or romfs not found after extracting .nup"
        exit 1
    }
    if (Test-Path -LiteralPath $exefsDir) { Remove-Item -Recurse -Force $exefsDir }
    if (Test-Path -LiteralPath $romfsDir) { Remove-Item -Recurse -Force $romfsDir }
    Move-Item -LiteralPath $foundExefs.FullName -Destination $exefsDir
    Move-Item -LiteralPath $foundRomfs.FullName -Destination $romfsDir
    Remove-Item -Recurse -Force $extractTmp -ErrorAction SilentlyContinue
}

# ---- 2. Lift NSOs & build static game module libraries ----
$toolchainFile = (Join-Path $source "recomp\cmake\clang64-mingw.cmake") -replace "\\", "/"
$liftBuildDir = Join-Path $workRoot "build-pkp"
$liftGenDir = Join-Path $workRoot "lift"
$pkpExe = Join-Path $Dir "pkp.exe"

if (-not (Test-Path -LiteralPath $pkpExe)) {
    Say "lifting NSOs and building game module libraries (Clang64 + Ninja)..."
    New-Item -ItemType Directory -Force -Path $liftBuildDir, $liftGenDir | Out-Null
    & $cmakeExe -S (Join-Path $source "recomp\games\pkp") -B $liftBuildDir -G Ninja `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchainFile" `
        -DCMAKE_BUILD_TYPE=Release `
        "-DNX_ROOT=$($workRoot -replace '\\', '/')" `
        "-DNX_PYTHON=$($pyExe -replace '\\', '/')" `
        "-DPKP_EXEFS=$($exefsDir -replace '\\', '/')" `
        "-DPKP_GEN=$($liftGenDir -replace '\\', '/')"
    if ($LASTEXITCODE -ne 0) { Say "cmake configure (recomp/games/pkp) failed"; exit 1 }

    & $cmakeExe --build $liftBuildDir --target pkp_modules -- -j $jobs
    if ($LASTEXITCODE -ne 0) { Say "cmake build (pkp_modules) failed"; exit 1 }

    # ---- 3. Build pkp.exe ----
    Say "compiling pkp.exe (runtime + lifted modules)..."
    $gameBuildDir = Join-Path $workRoot "build-game"
    New-Item -ItemType Directory -Force -Path $gameBuildDir | Out-Null
    & $cmakeExe -S (Join-Path $source "game-build") -B $gameBuildDir -G Ninja `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchainFile" `
        -DCMAKE_BUILD_TYPE=Release `
        -DPKP_RELEASE=ON `
        "-DPKP_LIB_DIR=$($liftBuildDir -replace '\\', '/')" `
        "-DPKP_EXEFS_DEFAULT=exefs"
    if ($LASTEXITCODE -ne 0) { Say "cmake configure (game-build) failed"; exit 1 }

    & $cmakeExe --build $gameBuildDir --target pkp -- -j $jobs
    if ($LASTEXITCODE -ne 0) { Say "cmake build (pkp.exe) failed"; exit 1 }

    $builtExe = Join-Path $gameBuildDir "pkp.exe"
    if (-not (Test-Path -LiteralPath $builtExe)) { Say "error: pkp.exe missing at $builtExe"; exit 1 }
    Copy-Item -LiteralPath $builtExe -Destination $pkpExe -Force

    foreach ($sub in @("fonts", "prompts")) {
        $srcSub = Join-Path $gameBuildDir $sub
        if (Test-Path -LiteralPath $srcSub) {
            Copy-Item -LiteralPath $srcSub -Destination $Dir -Recurse -Force
        }
    }
    $libusbDll = Join-Path $gameBuildDir "libusb-1.0.dll"
    if (Test-Path -LiteralPath $libusbDll) {
        Copy-Item -LiteralPath $libusbDll -Destination $Dir -Force
    }

    # Copy required MSYS2 Clang64 runtime DLLs via static PE import-table BFS (zero MSYS2 dependency at runtime)
    $dllCopyPy = Join-Path $workRoot "copy_clang64_dlls.py"
    $pyCode = @'
import os, shutil, struct, sys

def pe_imports(path):
    with open(path, 'rb') as f:
        data = f.read(4096)
        if data[:2] != b'MZ': return []
        pe_off = struct.unpack_from('<I', data, 0x3c)[0]
        f.seek(pe_off)
        hdr = f.read(256)
        if hdr[:4] != b'PE\0\0': return []
        n_sec, = struct.unpack_from('<H', hdr, 6)
        opt_sz, = struct.unpack_from('<H', hdr, 20)
        opt_off = pe_off + 24
        f.seek(opt_off)
        opt = f.read(opt_sz)
        magic, = struct.unpack_from('<H', opt, 0)
        dd_off = 112 if magic == 0x20b else 96
        n_dd, = struct.unpack_from('<I', opt, dd_off - 4)
        f.seek(opt_off + opt_sz)
        secs = []
        for _ in range(n_sec):
            s = f.read(40)
            vsz, va, rsz, rptr = struct.unpack_from('<4I', s, 8)
            secs.append((va, max(vsz, rsz), rptr))
        def r2o(rva):
            for va, sz, rp in secs:
                if va <= rva < va + sz:
                    return rp + (rva - va)
            return None
        def read_cstr(off):
            if off is None: return ''
            f.seek(off)
            buf = f.read(260)
            end = buf.find(b'\0')
            return (buf[:end] if end != -1 else buf).decode('ascii', 'ignore')
        out = []
        if n_dd > 1:
            imp_rva, _ = struct.unpack_from('<2I', opt, dd_off + 8)
            if imp_rva:
                off = r2o(imp_rva)
                while off is not None:
                    f.seek(off)
                    desc = f.read(20)
                    if len(desc) < 20 or desc == b'\0' * 20: break
                    name_rva, = struct.unpack_from('<I', desc, 12)
                    if not name_rva: break
                    n = read_cstr(r2o(name_rva))
                    if n: out.append(n)
                    off += 20
        if n_dd > 13:
            dly_rva, _ = struct.unpack_from('<2I', opt, dd_off + 13 * 8)
            if dly_rva:
                off = r2o(dly_rva)
                while off is not None:
                    f.seek(off)
                    desc = f.read(32)
                    if len(desc) < 32 or desc == b'\0' * 32: break
                    attrs, name_rva = struct.unpack_from('<2I', desc, 0)
                    if not name_rva: break
                    if attrs & 1:
                        n = read_cstr(r2o(name_rva))
                        if n: out.append(n)
                    off += 32
        return out

clang_bin, dst_dir, *roots = sys.argv[1:]
avail = {n.lower(): os.path.join(clang_bin, n) for n in os.listdir(clang_bin) if n.lower().endswith('.dll') and n.lower() != 'vulkan-1.dll'}
seen, queue = set(), list(roots)
while queue:
    cur = queue.pop(0)
    if not os.path.isfile(cur): continue
    for imp in pe_imports(cur):
        key = imp.lower()
        if key in avail and key not in seen:
            seen.add(key)
            src = avail[key]
            shutil.copy2(src, os.path.join(dst_dir, os.path.basename(src)))
            queue.append(src)
'@
    [System.IO.File]::WriteAllText($dllCopyPy, $pyCode, $utf8NoBom)
    & $pyExe $dllCopyPy $clang64Bin $Dir $pkpExe
    if ($LASTEXITCODE -ne 0) { Say "failed to copy runtime DLLs"; exit 1 }
}

# ---- 3b. Extract & translate NVN2 shaders to shader_cache/spirv ----
$spirvDir = Join-Path $Dir "shader_cache\spirv"
$spirvResults = Join-Path $spirvDir "results.tsv"
if (-not (Test-Path -LiteralPath $spirvResults)) {
    $harnessCache = Join-Path $env:LOCALAPPDATA "Switch2Recomp\_cache\pokopia_spirv_harness"
    $harnessExe = Join-Path $harnessCache "spirv_harness.exe"
    if (-not (Test-Path -LiteralPath $harnessExe)) {
        Say "downloading spirv_harness (PokopiaRecomp v0.15.0)..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        New-Item -ItemType Directory -Force -Path $harnessCache | Out-Null
        $tmpZip = Join-Path $env:TEMP "PokopiaRecomp-0.15.0-win64.zip"
        Invoke-WebRequest -Uri "https://github.com/Dittobyte/Recompia/releases/download/v0.15.0/PokopiaRecomp-0.15.0-win64.zip" -OutFile $tmpZip -UseBasicParsing
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match '/tools/spirv_harness/(.+)$' -and $entry.Name) {
                $dst = Join-Path $harnessCache $Matches[1]
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dst, $true)
            }
        }
        $zip.Dispose()
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    }
    $corpusDir = Join-Path $Dir "shader_cache\corpus"
    $extractPy = Join-Path $source "tools\shaders\ampere\extract_corpus.py"
    $shaderJobs = [Math]::Max(1, [Math]::Min($cpuCount, 12))
    Say "extracting NVN2 shader corpus..."
    & $pyExe -I $extractPy --romfs (Join-Path $Dir "romfs") --main (Join-Path $Dir "exefs\main") --out $corpusDir --jobs $shaderJobs
    if ($LASTEXITCODE -ne 0) { Say "shader corpus extraction failed"; exit 1 }
    Say "translating shaders to SPIR-V..."
    New-Item -ItemType Directory -Force -Path $spirvDir | Out-Null
    & $harnessExe --batch $corpusDir --out $spirvDir --jobs $shaderJobs --no-val
    if ($LASTEXITCODE -ne 0) { Say "spirv_harness failed"; exit 1 }
    Remove-Item -Recurse -Force -LiteralPath $corpusDir -ErrorAction SilentlyContinue
}

# Compact loose .spv files into shader_cache/spirv.archive/000000.pack (NXSPACK1 + zstd) to save ~15+ GB on NTFS
$archiveDir = Join-Path $Dir "shader_cache\spirv.archive"
$archivePack = Join-Path $archiveDir "000000.pack"
if ((Test-Path -LiteralPath $spirvResults) -and (-not (Test-Path -LiteralPath $archivePack))) {
    $packPy = Join-Path $workRoot "pack_shaders.py"
    $packCode = @'
import ctypes, glob, os, struct, sys

spirv_dir, out_pack, zstd_dll = sys.argv[1], sys.argv[2], sys.argv[3]
spv_files = sorted(glob.glob(os.path.join(spirv_dir, "*.spv")))
if not spv_files:
    sys.exit(0)

lib = ctypes.CDLL(zstd_dll)
lib.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
lib.ZSTD_compressBound.restype = ctypes.c_size_t
lib.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
lib.ZSTD_compress.restype = ctypes.c_size_t
lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
lib.ZSTD_isError.restype = ctypes.c_uint

os.makedirs(os.path.dirname(out_pack), exist_ok=True)
tmp_pack = out_pack + ".tmp"
entries = []
with open(tmp_pack, "wb") as f:
    f.write(b"\x00" * 32)  # PackHeader placeholder
    offset = 32
    for path in spv_files:
        name = os.path.splitext(os.path.basename(path))[0]
        if len(name) != 16:
            continue
        raw = open(path, "rb").read()
        usize = len(raw)
        if usize == 0 or (usize % 4) != 0:
            continue
        bound = lib.ZSTD_compressBound(usize)
        dst = ctypes.create_string_buffer(bound)
        csize = lib.ZSTD_compress(dst, bound, raw, usize, 6)
        if lib.ZSTD_isError(csize):
            raise RuntimeError(f"ZSTD_compress failed on {name}")
        f.write(dst.raw[:csize])
        entries.append((name.encode("ascii"), 0, offset, csize, usize))
        offset += csize
    index_offset = offset
    for h16, line_hash, off, csize, usize in entries:
        f.write(struct.pack("<16sQQII", h16, line_hash, off, csize, usize))
    f.seek(0)
    f.write(struct.pack("<8sIIQQ", b"NXSPACK1", 1, len(entries), index_offset, 0))

os.replace(tmp_pack, out_pack)
for path in spv_files:
    try:
        os.remove(path)
    except OSError:
        pass
print(f"packed {len(entries)} shaders -> {out_pack} ({index_offset // (1024*1024)} MiB)")
'@
    [System.IO.File]::WriteAllText($packPy, $packCode, $utf8NoBom)
    $zstdDll = Join-Path $clang64Bin "libzstd.dll"
    Say "compacting shader cache into spirv.archive..."
    & $pyExe $packPy $spirvDir $archivePack $zstdDll
    if ($LASTEXITCODE -ne 0) { Say "warning: shader archive compaction failed (loose .spv files kept)" }
}

$pkpIniPath = Join-Path $Dir "pkp.ini"
if (-not (Test-Path -LiteralPath $pkpIniPath)) {
    $iniText = "[nvn]`nshader_cache = shader_cache/spirv`ndump_missing = shader_cache/missing`n"
    [System.IO.File]::WriteAllText($pkpIniPath, $iniText, $utf8NoBom)
}

# ---- 4. Pre-launch UI, config, shortcuts & Windows uninstaller ----
$repoRoot = Resolve-Path (Join-Path $source "..\..\..")
$isLauncherExe = $false
if ($LauncherUiPath -and (Test-Path -LiteralPath $LauncherUiPath)) {
    $launcherUiSrc = $LauncherUiPath
    $isLauncherExe = $launcherUiSrc.ToLower().EndsWith(".exe")
} else {
    $toolsExe = Join-Path $repoRoot "tools\game_launcher.exe"
    $exeCand = Join-Path $repoRoot "game_launcher.exe"
    if (Test-Path -LiteralPath $toolsExe) { $launcherUiSrc = $toolsExe; $isLauncherExe = $true }
    elseif (Test-Path -LiteralPath $exeCand) { $launcherUiSrc = $exeCand; $isLauncherExe = $true }
    else { $launcherUiSrc = Join-Path $repoRoot "src\game_launcher.py" }
}

$launcherUiDst = Join-Path $Dir $(if ($isLauncherExe) { "game_launcher.exe" } else { "game_launcher.py" })
if (Test-Path -LiteralPath $launcherUiSrc) {
    Copy-Item -LiteralPath $launcherUiSrc -Destination $launcherUiDst -Force
}

$launchConfigPath = Join-Path $Dir "launch_options.json"
$tplPath = Join-Path $source "launch_options_template.json"
if (Test-Path -LiteralPath $tplPath) {
    $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tpl.working_dir = $Dir
    $tpl | Add-Member -NotePropertyName "rom_path" -NotePropertyValue $Nup -Force
    $tpl.command = @($pkpExe, "--game", $Dir, "--exefs", "{rom}", "--window")
    $jsonOut = $tpl | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($launchConfigPath, $jsonOut, $utf8NoBom)
}

$iconDst = Join-Path $Dir "game_icon.ico"
if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
    Copy-Item -LiteralPath $IconPath -Destination $iconDst -Force
} elseif (Test-Path -LiteralPath (Join-Path $source "game_icon.ico")) {
    Copy-Item -LiteralPath (Join-Path $source "game_icon.ico") -Destination $iconDst -Force
}

$pngSrc = Join-Path $source "game_icon.png"
$pngDst = Join-Path $Dir "game_icon.png"
if (Test-Path -LiteralPath $pngSrc) {
    Copy-Item -LiteralPath $pngSrc -Destination $pngDst -Force
}

$runner = Join-Path $Dir "pkp.cmd"
$postTranslate = @'
if exist "%~dp0shader_cache\missing\manifest.tsv" (
    if exist "%LOCALAPPDATA%\Switch2Recomp\_cache\pokopia_spirv_harness\spirv_harness.exe" (
        "%LOCALAPPDATA%\Switch2Recomp\_cache\pokopia_spirv_harness\spirv_harness.exe" --batch "%~dp0shader_cache\missing" --out "%~dp0shader_cache\missing_out" --no-val >nul 2>nul
        if exist "%~dp0shader_cache\missing_out\results.tsv" (
            for %%F in ("%~dp0shader_cache\missing_out\*.spv") do move /Y "%%F" "%~dp0shader_cache\spirv\" >nul 2>nul
            more +1 "%~dp0shader_cache\missing_out\results.tsv" >> "%~dp0shader_cache\spirv\results.tsv"
        )
        rmdir /s /q "%~dp0shader_cache\missing" 2>nul
        rmdir /s /q "%~dp0shader_cache\missing_out" 2>nul
    )
)
'@
if ($isLauncherExe -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
    $cmdText = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
"%~dp0game_launcher.exe" --config "%~dp0launch_options.json" %*
$postTranslate
"@
} else {
    $cmdText = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "NXRT_DISPLAY_WIDTH=1280"
set "NXRT_DISPLAY_HEIGHT=720"
"%~dp0pkp.exe" --game "%~dp0" --exefs "%~dp0exefs" --window %*
"@
}
[System.IO.File]::WriteAllText($runner, $cmdText, $utf8NoBom)

$safeShortcutName = ($ShortcutName -replace '[<>:"/\\|?*]+', ' -').Trim()
if (-not $safeShortcutName) { $safeShortcutName = "Pokemon Pokopia" }

$startMenuPrograms = [Environment]::GetFolderPath("Programs")
$shortcutDirs = @((Join-Path $startMenuPrograms $safeShortcutName))
if (-not $NoDesktopShortcut) {
    $shortcutDirs += [Environment]::GetFolderPath("Desktop")
}

$wsh = New-Object -ComObject WScript.Shell
foreach ($sdir in $shortcutDirs) {
    New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    $linkPath = Join-Path $sdir "$safeShortcutName.lnk"
    $link = $wsh.CreateShortcut($linkPath)
    $link.TargetPath = $runner
    $link.WorkingDirectory = $Dir
    $link.Description = "$safeShortcutName - Native PC port (F11 Fullscreen)"
    if (Test-Path -LiteralPath $iconDst) { $link.IconLocation = "$iconDst,0" }
    $link.Save()
}

# ---- 5. Clean up temporary build files ----
Say "cleaning up temporary build files in $Dir..."
if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
}

# ---- 6. Windows Apps & Features uninstaller ----
$uninstKeyName = "Switch2Recomp_" + ($safeShortcutName -replace '[^A-Za-z0-9_-]', '_')
$uninstRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstKeyName"
$uninstPs1 = Join-Path $Dir "uninstall.ps1"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "$safeShortcutName.lnk"
$startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) $safeShortcutName
$eAcute = [char]0x00E9
$uninstScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$res = [System.Windows.Forms.MessageBox]::Show(
    "Voulez-vous d${eAcute}sinstaller $safeShortcutName ?``n``nLe dossier d'installation et les raccourcis seront supprim${eAcute}s.``nVotre fichier ROM (.nup) et vos sauvegardes ne seront PAS supprim${eAcute}s.",
    "D${eAcute}sinstaller $safeShortcutName",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if (`$res -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
Remove-Item -LiteralPath "$desktopLnk" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$startMenuDir" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$uninstRegPath" -Recurse -Force -ErrorAction SilentlyContinue
`$cmd = 'ping 127.0.0.1 -n 2 > nul & rmdir /s /q "$Dir"'
Start-Process -FilePath "cmd.exe" -ArgumentList "/c", `$cmd -WindowStyle Hidden
"@
[System.IO.File]::WriteAllText($uninstPs1, $uninstScript, (New-Object System.Text.UTF8Encoding($true)))

New-Item -Path $uninstRegPath -Force | Out-Null
$estSizeKb = [math]::Round(((Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
Set-ItemProperty -Path $uninstRegPath -Name "DisplayName" -Value $safeShortcutName
Set-ItemProperty -Path $uninstRegPath -Name "Publisher" -Value "Switch2Recomp / Recompia"
Set-ItemProperty -Path $uninstRegPath -Name "InstallLocation" -Value $Dir
Set-ItemProperty -Path $uninstRegPath -Name "UninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "QuietUninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "NoRepair" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "EstimatedSize" -Value $estSizeKb -Type DWord
if (Test-Path -LiteralPath $iconDst) { Set-ItemProperty -Path $uninstRegPath -Name "DisplayIcon" -Value $iconDst }

Say "installed. Start the game from the Start menu or the desktop shortcut (windowed 720p by default, F11 for fullscreen)."
