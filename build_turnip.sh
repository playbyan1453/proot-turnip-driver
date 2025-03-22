#!/bin/bash

# Script to cross-compile Mesa for ARM64 and ARMHF with Vulkan KGSL driver
# Target: ARM64 and ARMHF (armv7hf) for Termux's Proot System

# Exit on any error
set -e

# Colors for output
GREEN='\033[0;32m'
WHITE='\033[0;37m'
RED='\033[0;31m'
NC='\033[0m'  # No Color

# Set environment variables
MESA_VERSION="${1:-${MESA_VERSION:-24.1.0}}"
BUILD_DATE=$(date +"%F" | sed 's/-//g')
echo -e "${GREEN}Starting Mesa cross-compilation for ARM64 and ARMHF (version $MESA_VERSION)...${NC}"

# https://gitlab.freedesktop.org/Danil/mesa/-/archive/review/a750-changes/mesa-review-a750-changes.tar.gz
# MESA_TARBALL="mesa-review-a750-changes.tar.gz"
# MESA_URL="https://gitlab.freedesktop.org/Danil/mesa/-/archive/review/a750-changes/$MESA_TARBALL"

# Set working directory and Mesa tarball details
MESA_TARBALL="mesa-mesa-$MESA_VERSION.tar.gz"
MESA_URL="https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-$MESA_VERSION/$MESA_TARBALL"

WORK_DIR="${HOME}/mesa-$MESA_VERSION"
MESA_SRC_DIR="$WORK_DIR/mesa-$MESA_VERSION-src"
OUTPUT_DIR="${HOME}/mesa-build"
PATCHES_DIR="${GITHUB_WORKSPACE:-$(pwd)}/patches"

# Ensure working and output directories exist
mkdir -p "$WORK_DIR" || {
    echo -e "${RED}Error: Failed to create working directory $WORK_DIR${NC}" >&2
    exit 1
}
mkdir -p "$OUTPUT_DIR" || {
    echo -e "${RED}Error: Failed to create output directory $OUTPUT_DIR${NC}" >&2
    exit 1
}
cd "$WORK_DIR" || {
    echo -e "${RED}Error: Failed to change to working directory $WORK_DIR${NC}" >&2
    exit 1
}

# Download Mesa tarball if not present
if [ ! -f "$MESA_TARBALL" ]; then
    echo -e "${GREEN}Downloading Mesa $MESA_VERSION...${NC}"
    wget --continue "$MESA_URL" || {
        echo -e "${RED}Error: Failed to download Mesa from $MESA_URL${NC}" >&2
        exit 1
    }
fi

# Extract tarball if source directory doesn't exist
if [ ! -d "$MESA_SRC_DIR" ]; then
    echo -e "${GREEN}Extracting Mesa $MESA_VERSION into $MESA_SRC_DIR...${NC}"
    mkdir -p "$MESA_SRC_DIR" || {
        echo -e "${RED}Error: Failed to create $MESA_SRC_DIR${NC}" >&2
        exit 1
    }
    tar -xf "$MESA_TARBALL" --strip-components=1 -C "$MESA_SRC_DIR" || {
        echo -e "${RED}Error: Failed to extract $MESA_TARBALL into $MESA_SRC_DIR${NC}" >&2
        exit 1
    }
fi

# Apply patches from /patches folder
if [ "$USE_PATCHES" = "true" ]; then
    if [ -d "$PATCHES_DIR" ]; then
        echo -e "${GREEN}Applying patches from $PATCHES_DIR...${NC}"
        cd "$MESA_SRC_DIR" || {
            echo -e "${RED}Error: Failed to change to $MESA_SRC_DIR${NC}" >&2
            exit 1
        }
        for patch in "$PATCHES_DIR"/*.patch; do
            if [ -f "$patch" ]; then
                echo -e "${GREEN}Applying patch: $(basename "$patch")${NC}"
                if ! patch -p1 < "$patch"; then
                    echo -e "${WHITE}Warning: Failed to apply patch $(basename "$patch"), continuing...${NC}" >&2
                fi
            else
                echo -e "${WHITE}No .patch files found in $PATCHES_DIR${NC}"
                break
            fi
        done
    else
        echo -e "${WHITE}No patches directory found at $PATCHES_DIR, skipping patch application${NC}"
    fi
else
    echo -e "${WHITE}USE_PATCHES is false, skipping patch application${NC}"
fi

build_mesa() {
    local ARCH=$1
    local TRIPLE=$2
    local CROSS_FILE="$WORK_DIR/cross-$ARCH.ini"
    local BUILD_DIR="$WORK_DIR/build-$ARCH"
    local INSTALL_DIR="$WORK_DIR/install-$ARCH"
    local OUTPUT_FILE="$OUTPUT_DIR/mesa-vulkan-kgsl_$MESA_VERSION-$BUILD_DATE-$ARCH.deb"

    if [ ! -f "$CROSS_FILE" ]; then
        echo -e "${RED}Error: Cross-compilation file $CROSS_FILE not found${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Configuring Mesa for $ARCH...${NC}"
    cd "$MESA_SRC_DIR" || {
        echo -e "${RED}Error: Failed to change to $MESA_SRC_DIR${NC}" >&2
        exit 1
    }
    
    if [ "$ARCH" = "arm64" ]; then
        LIBDIR="lib/aarch64-linux-gnu"
    else  # armhf
        LIBDIR="lib/arm-linux-gnueabihf"
    fi

    rm -rf "$BUILD_DIR"  # Clean previous build
    meson setup "$BUILD_DIR" --cross-file "$CROSS_FILE" --prefix /usr --libdir "$LIBDIR" \
        -D c_link_args='-Wl,--no-as-needed' -D cpp_link_args='-Wl,--no-as-needed' \
        -D platforms=x11,wayland -D gallium-drivers=freedreno \
        -D vulkan-drivers=freedreno -D freedreno-kmds=msm,kgsl \
        -D dri3=enabled -D buildtype=release -D glx=disabled \
        -D egl=disabled -D gles1=disabled -D gles2=disabled \
        -D gallium-xa=disabled -D opengl=false -D shared-glapi=false \
        -D b_lto=true -D b_ndebug=true -D cpp_rtti=false \
        -D gbm=disabled -D llvm=disabled -D shared-llvm=disabled \
        -D xmlconfig=disabled || {
        echo -e "${RED}Error: Meson setup failed for $ARCH${NC}" >&2
        exit 1
    }

    echo -e "${GREEN}Building Mesa for $ARCH...${NC}"
    ninja -C "$BUILD_DIR" || {
        echo -e "${RED}Error: Compilation failed for $ARCH${NC}" >&2
        exit 1
    }

    echo -e "${GREEN}Installing Mesa for $ARCH...${NC}"
    mkdir -p "$INSTALL_DIR" || {
        echo -e "${RED}Error: Failed to create install directory $INSTALL_DIR${NC}" >&2
        exit 1
    }
    DESTDIR="$INSTALL_DIR" ninja -C "$BUILD_DIR" install || {
        echo -e "${RED}Error: Installation failed for $ARCH${NC}" >&2
        exit 1
    }

    echo -e "${GREEN}Packaging $ARCH build as .deb...${NC}"
    # Create DEBIAN directory for package metadata
    mkdir -p "$INSTALL_DIR/DEBIAN" || {
        echo -e "${RED}Error: Failed to create DEBIAN directory in $INSTALL_DIR${NC}" >&2
        exit 1
    }

    # Write the control file
    cat > "$INSTALL_DIR/DEBIAN/control" << EOF
Package: mesa-vulkan-drivers
Source: mesa
Version: ${MESA_VERSION}-${BUILD_DATE}
Architecture: ${ARCH}
Maintainer: Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>
Depends: libvulkan1, python3:any, libc6 (>= 2.38), libdrm-amdgpu1 (>= 2.4.121), libdrm2 (>= 2.4.121), libelf1t64 (>= 0.142), libexpat1 (>= 2.0.1), libgcc-s1 (>= 4.2), libllvm19 (>= 1:19.1.0), libstdc++6 (>= 11), libwayland-client0 (>= 1.23.0), libx11-xcb1 (>= 2:1.8.7), libxcb-dri3-0 (>= 1.17.0), libxcb-present0 (>= 1.17.0), libxcb-randr0 (>= 1.13), libxcb-shm0, libxcb-sync1, libxcb-xfixes0, libxcb1 (>= 1.9.2), libxshmfence1, libzstd1 (>= 1.5.5), zlib1g (>= 1:1.2.3.3)
Provides: vulkan-icd
Section: libs
Priority: optional
Multi-Arch: same
Homepage: https://mesa3d.org/
Description: Mesa Vulkan graphics drivers
 Vulkan is a low-overhead 3D graphics and compute API. This package
 includes Vulkan drivers provided by the Mesa project.
Original-Maintainer: Debian X Strike Force <debian-x@lists.debian.org>
EOF

    # Build the .deb package
    dpkg-deb --build --root-owner-group "$INSTALL_DIR" "$OUTPUT_FILE" || {
        echo -e "${RED}Error: Failed to create .deb package $OUTPUT_FILE${NC}" >&2
        exit 1
    }
}

# Create cross-compilation config files if they don't exist
if [ ! -f "$WORK_DIR/cross-arm64.ini" ]; then
    echo -e "${GREEN}Creating cross-compilation config for arm64...${NC}"
    cat > "$WORK_DIR/cross-arm64.ini" << EOF
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkgconfig = 'pkg-config'

[properties]
pkg_config_libdir = '/usr/lib/aarch64-linux-gnu/pkgconfig'
sys_root = '/usr/aarch64-linux-gnu'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-march=armv8-a']
cpp_args = ['-march=armv8-a']
EOF
fi

if [ ! -f "$WORK_DIR/cross-armhf.ini" ]; then
    echo -e "${GREEN}Creating cross-compilation config for armhf...${NC}"
    cat > "$WORK_DIR/cross-armhf.ini" << EOF
[binaries]
c = 'arm-linux-gnueabihf-gcc'
cpp = 'arm-linux-gnueabihf-g++'
ar = 'arm-linux-gnueabihf-ar'
strip = 'arm-linux-gnueabihf-strip'
pkgconfig = 'pkg-config'

[properties]
pkg_config_libdir = '/usr/lib/arm-linux-gnueabihf/pkgconfig'
sys_root = '/usr/arm-linux-gnueabihf'

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7-a'
endian = 'little'

[built-in options]
c_args = ['-march=armv7-a', '-mthumb', '-mfpu=neon-vfpv4', '-mfloat-abi=hard']
cpp_args = ['-march=armv7-a', '-mthumb', '-mfpu=neon-vfpv4', '-mfloat-abi=hard']
EOF
fi

# Build for ARM64
echo -e "${GREEN}Starting ARM64 build...${NC}"
build_mesa "arm64" "aarch64-linux-gnu"

# Build for ARMHF (armv7hf)
echo -e "${GREEN}Starting ARMHF build...${NC}"
build_mesa "armhf" "arm-linux-gnueabihf"

# Clean up source (optional, commented out by default)
# echo -e "${GREEN}Cleaning up source directory...${NC}"
# rm -rf "$MESA_SRC_DIR"

echo -e "${GREEN}Mesa $MESA_VERSION cross-compiled for ARM64 and ARMHF successfully!${NC}"
echo -e "${GREEN}Output files:${NC}"
echo -e "  - $OUTPUT_DIR/mesa-vulkan-kgsl_$MESA_VERSION-$BUILD_DATE-arm64.deb (for ARM64)"
echo -e "  - $OUTPUT_DIR/mesa-vulkan-kgsl_$MESA_VERSION-$BUILD_DATE-armhf.deb (for ARMHF)"
