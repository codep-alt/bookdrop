-- Manga runtime downloader for Bookdrop.
--
-- Detects the device platform and downloads the correct Rust server binary from
-- the upstream RakuYomi GitHub releases.  Runs on first use when the user taps
-- the Manga tab; cancellable via the Trapper dismissable-run pattern.

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local MangaDownloader = {}

--- Read the first 4 bytes of a file to check its binary format.
--- @param path string
--- @return string|nil magic  4-byte string, or nil if unreadable
local function readMagic(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local magic = f:read(4)
  f:close()
  return magic
end

--- Check whether the server binary at `path` matches the current device.
--- Returns true if the binary is valid for this platform, false if it should
--- be re-downloaded, and nil + err if the file doesn't exist or is unreadable.
--- @param path string
--- @return boolean|nil valid
--- @return string|nil err
function MangaDownloader.validateBinary(path)
  local magic = readMagic(path)
  if not magic then
    return nil, "binary not found"
  end
  local jit = require("jit")

  -- ELF magic: \x7fELF (Linux, Kindle, Kobo, PocketBook, etc.)
  local is_elf = magic:byte(1) == 0x7f and magic:byte(2) == 0x45
      and magic:byte(3) == 0x4c and magic:byte(4) == 0x46

  -- Mach-O 64-bit magic (macOS): 0xFEEDFACF or 0xCFFAEDFE
  local macho_le = magic:byte(1) == 0xcf and magic:byte(2) == 0xfa
      and magic:byte(3) == 0xed and magic:byte(4) == 0xfe
  local macho_be = magic:byte(1) == 0xfe and magic:byte(2) == 0xed
      and magic:byte(3) == 0xfa and magic:byte(4) == 0xcf

  if jit.os == "OSX" then
    return macho_le or macho_be, nil
  end
  -- Everything else (Kindle, Kobo, desktop Linux): expects ELF
  return is_elf, nil
end

local RAKUYOMI_REPO = "tachibana-shin/rakuyomi"
-- Use the /latest/download redirect URL instead of hitting the GitHub API.
-- This avoids an extra HTTPS round-trip and works even when LuaSocket's
-- TLS handling is shaky: the redirect points directly at the release asset.
local DOWNLOAD_URL = "https://github.com/" .. RAKUYOMI_REPO .. "/releases/latest/download"

--- Detect which RakuYomi platform name this device needs.
--- @return string platform  One of "macos", "desktop", "kindle", "kindlehf", "kindlea9", "aarch64"
function MangaDownloader.detectPlatform()
  local jit = require("jit")

  -- macOS emulator
  if jit.os == "OSX" then
    return "macos"
  end

  if Device:isKindle() then
    local f = io.open("/proc/cpuinfo", "r")
    if f then
      local cpuinfo = f:read("*a"):lower()
      f:close()
      -- Kindle Basic 2024+ (Cortex-A9)
      if cpuinfo:find("cortex%-a9") then
        return "kindlea9"
      end
      -- Hard-float Kindles (PW2+, Voyage, Oasis, etc.) have VFP/NEON
      if cpuinfo:find("vfpv") or cpuinfo:find("neon") then
        return "kindlehf"
      end
    end
    -- Older Kindles: soft-float
    return "kindle"
  end

  -- Generic Linux (Kobo, PocketBook, desktop, etc.)
  if jit.arch == "arm64" or jit.arch == "aarch64" then
    return "aarch64"
  end
  return "desktop"
end

--- Download and install the RakuYomi server binaries for this device.
---
--- Call from inside Trapper:wrap().  Uses Trapper:dismissableRunInSubprocess
--- so the user sees progress and can cancel.
---
--- @param target_dir string  The manga/ directory path
--- @return boolean ok
--- @return string|nil msg   Error message on failure, or nil on success
function MangaDownloader.downloadAndInstall(target_dir)
  local Trapper = require("ui/trapper")

  -- 1. Detect platform and build the download URL
  local platform = MangaDownloader.detectPlatform()
  local zip_url = string.format("%s/rakuyomi-%s.zip", DOWNLOAD_URL, platform)
  local zip_path = target_dir .. "/rakuyomi-tmp.zip"

  os.remove(zip_path)

  -- 2. Download with curl (macOS / desktop Linux) or busybox wget (Kindle)
  local download_cmd = string.format(
    'curl -L -f -sS -o "%s" "%s" 2>/dev/null', zip_path, zip_url)
  local download_ok = os.execute(download_cmd) == 0

  if not download_ok then
    download_cmd = string.format(
      'busybox wget -q -O "%s" "%s" 2>/dev/null', zip_path, zip_url)
    download_ok = os.execute(download_cmd) == 0
  end

  if not download_ok then
    os.remove(zip_path)
    return false, "download failed"
  end

  -- 3. Extract server + cbz_metadata_reader from the zip
  local function runUnzip(tool)
    return os.execute(string.format(
      '%s -o -j "%s" "rakuyomi.koplugin/server" "rakuyomi.koplugin/cbz_metadata_reader" -d "%s" > /dev/null 2>&1',
      tool, zip_path, target_dir))
  end

  local extract_ok = runUnzip("unzip") == 0
  if not extract_ok then
    extract_ok = runUnzip("busybox unzip") == 0
  end

  os.remove(zip_path)

  if not extract_ok then
    return false, "could not extract the manga runtime"
  end

  -- 4. Make binaries executable
  for _, name in ipairs({ "server", "cbz_metadata_reader" }) do
    os.execute('chmod +x "' .. target_dir .. "/" .. name .. '" 2>/dev/null')
  end

  -- 5. Verify both files exist
  local function fileExists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
  end
  if not fileExists(target_dir .. "/server") then
    return false, "server binary was not extracted"
  end
  if not fileExists(target_dir .. "/cbz_metadata_reader") then
    return false, "cbz_metadata_reader binary was not extracted"
  end

  return true, nil
end

return MangaDownloader
