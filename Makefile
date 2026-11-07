ifndef THEOS
  CODEX_COMPAT := $(shell echo "$$PATH" | grep -o '[^:]*TheosCoreCompat' | head -n 1)
  ifneq ($(CODEX_COMPAT),)
    CODEX_APP := $(patsubst %/Helpers/TheosCoreCompat,%,$(CODEX_COMPAT))
    export THEOS := $(CODEX_APP)/TheosRuntime/theos
    export PATH := $(CODEX_APP)/TheosRuntime/usr/bin:$(CODEX_APP)/TheosRuntime/usr/lib/llvm-16/bin:$(CODEX_APP)/TheosRuntime/theos/bin:$(CODEX_APP)/TheosRuntime/bin:$(PATH)
    export PERL5LIB := $(CODEX_APP)/TheosRuntime/usr/share/perl5/5.32:$(CODEX_APP)/TheosRuntime/usr/lib/perl5/5.32
  endif
endif

TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

# OLLVM 参数由 CodexApp 设置层通过 CA_OLLVM_ARM64_CFLAGS /
# CA_OLLVM_ARM64E_CFLAGS 注入；这里不覆盖用户选择。

export PERL5LIB := $(THEOS)/../usr/share/perl5/5.32:$(THEOS)/../usr/lib/perl5/5.32:$(PERL5LIB)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplashAway

SplashAway_FILES = Tweak.x
SplashAway_CFLAGS = -fobjc-arc -fno-modules -Wno-unused-variable -Wno-unused-value -Wno-unused-function -Wno-deprecated-declarations
SplashAway_LDFLAGS = -Wl,-no_fixup_chains
SplashAway_FRAMEWORKS = UIKit QuartzCore Foundation Vision CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

OUTPUT_NAME := 开屏广告走开

before-package::
	@python3 -c "import os,sys; d=sys.argv[1]; [os.replace(os.path.join(d,'SplashAway'+e), os.path.join(d,sys.argv[2]+e)) for e in ('.dylib','.plist') if os.path.exists(os.path.join(d,'SplashAway'+e))]" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries" "$(OUTPUT_NAME)"

after-all::
	@mkdir -p dist
	@cp -f .theos/obj/debug/SplashAway.dylib "dist/$(OUTPUT_NAME).dylib"
	@cp -f SplashAway.plist "dist/$(OUTPUT_NAME).plist"
	@echo "==> 已同步最新双架构 dylib 至 dist/ (arm64 + arm64e)"

after-package::
	@mkdir -p dist
	@cp -f .theos/obj/debug/SplashAway.dylib "dist/$(OUTPUT_NAME).dylib"
	@cp -f SplashAway.plist "dist/$(OUTPUT_NAME).plist"
	@python3 -c "import os; [os.remove('dist/SplashAway'+e) for e in ('.dylib','.plist') if os.path.exists('dist/SplashAway'+e)]"
	@python3 -c "import glob, os; files = sorted(glob.glob('packages/*.deb'), key=os.path.getmtime); [os.remove(f) for f in files[:-1]] if len(files) > 1 else None"
	@echo "==> 产物维护完毕：dist/ 仅保留最新双架构 dylib，packages/ 仅保留最新 deb"
