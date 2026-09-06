.PHONY: build verify clean
.PHONY: xcode-generate xcode-build xcode-sign xcode-run xcode-smoke xcode-lifecycle-smoke xcode-trace-smoke

XCODE_DERIVED_DATA ?= build/NativDevelopmentDerivedData
# Build-product name; must match NATIV_PRODUCT_NAME in the xcconfig chain.
# Override to give a worktree its own app bundle, e.g.
#   make xcode-run NATIV_PRODUCT_NAME=nativ-trace
NATIV_PRODUCT_NAME ?= Nativ
NATIV_APP := $(XCODE_DERIVED_DATA)/Build/Products/Debug/$(NATIV_PRODUCT_NAME).app
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py

verify:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --verify-only

verify-python:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --skip-install --verify-only

clean:
	rm -rf build dist

xcode-generate:
	xcodegen generate

xcode-build: xcode-generate
	xcodebuild -project Nativ.xcodeproj -scheme Nativ -configuration Debug -derivedDataPath $(XCODE_DERIVED_DATA) NATIV_PRODUCT_NAME=$(NATIV_PRODUCT_NAME) CODE_SIGNING_ALLOWED=NO build

xcode-sign: xcode-build
	./scripts/sign_macos_debug.sh $(abspath $(NATIV_APP))

xcode-run: xcode-sign
	./scripts/open_macos_debug.sh $(abspath $(NATIV_APP))

xcode-smoke: xcode-build
	$(NATIV_APP)/Contents/MacOS/$(NATIV_PRODUCT_NAME) --smoke-test

xcode-lifecycle-smoke: xcode-build
	$(NATIV_APP)/Contents/MacOS/$(NATIV_PRODUCT_NAME) --lifecycle-smoke-test

xcode-trace-smoke: xcode-build
	$(NATIV_APP)/Contents/MacOS/$(NATIV_PRODUCT_NAME) --trace-smoke-test
