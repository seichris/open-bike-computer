# CanAirIO Project
# Author: @hpsaturn
# pre-build script, setting up build environment

import os.path
from platformio import util
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from SCons.Script import DefaultEnvironment

env = DefaultEnvironment()
TOOLS_DIR = Path(env.get("PROJECT_DIR")).resolve() / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from firmware_build_identity import firmware_git_identity

try:
    import configparser
except ImportError:
    import ConfigParser as configparser

# get platformio environment variables
config = configparser.ConfigParser()
config.read("platformio.ini")

# get platformio source path
srcdir = env.get("PROJECTSRC_DIR")
flavor = env.get("PIOENV")
firmware_target = env.GetProjectOption("custom_firmware_target", flavor)
revision = config.get("common","revision")
version = config.get("common", "version")
build_timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
git_sha = firmware_git_identity(Path(env.get("PROJECT_DIR")).resolve().parent)

dfl_lat = os.environ.get('ICENAV3_LAT')
dfl_lon = os.environ.get('ICENAV3_LON')

# print ("environment:")
# print (env.Dump())

# get runtime credentials and put them to compiler directive
env.Append(BUILD_FLAGS=[
    u'-DREVISION=' + revision + '',
    u'-DVERSION=\\"' + version + '\\"',
    u'-DFLAVOR=\\"' + firmware_target + '\\"',
    u'-DGIT_SHA=\\"' + git_sha + '\\"',
    u'-DBUILD_TIMESTAMP=\\"' + build_timestamp + '\\"',
    u'-D'+ flavor + '=1'
    ])

if dfl_lat != None and dfl_lon != None:
    print ("default lat: "+dfl_lat)
    print ("default lon: "+dfl_lon)
    env.Append(BUILD_FLAGS=[
        u'-DDEFAULT_LAT=' + dfl_lat + '',
        u'-DDEFAULT_LON=' + dfl_lon + ''
        ])

# NeoGps Config files
config_path = "lib/gps/GPSfix_cfg.h"
output_path =  ".pio/libdeps/" + flavor + "/NeoGPS/src" 
target_path = output_path + "/GPSfix_cfg.h"
os.makedirs(output_path, 0o755, True)
shutil.copy(config_path , target_path)

config_path = "lib/gps/NeoGPS_cfg.h"
output_path =  ".pio/libdeps/" + flavor + "/NeoGPS/src" 
target_path = output_path + "/NeoGPS_cfg.h"
os.makedirs(output_path, 0o755, True)
shutil.copy(config_path , target_path)

config_path = "lib/gps/NMEAGPS_cfg.h"
output_path =  ".pio/libdeps/" + flavor + "/NeoGPS/src" 
target_path = output_path + "/NMEAGPS_cfg.h"
os.makedirs(output_path, 0o755, True)
shutil.copy(config_path , target_path)
