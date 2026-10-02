#!/bin/zsh
set -euo pipefail
task_root=${0:A:h}
task_archive=${LECTURELENS_ARCHIVE:-"$task_root/../Lecture Lens.zip"}
task_stage=$(mktemp -d /private/tmp/lecturelens-build.XXXXXX)
trap 'rm -rf "$task_stage"' EXIT
task_stage_app="$task_stage/Lecture Lens.app"
mkdir -p "$task_stage_app/Contents/MacOS" "$task_stage_app/Contents/Resources" "$task_stage_app/Contents/Frameworks"
task_vendor="$task_root/Vendor/SherpaOnnx"
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  -import-objc-header "$task_vendor/c-api.h" "$task_root"/Sources/*.swift \
  -L "$task_vendor" -l sherpa-onnx-c-api -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$task_stage_app/Contents/MacOS/LectureLens"
cp "$task_root/Info.plist" "$task_stage_app/Contents/Info.plist"
task_coursepack="$task_root/Resources/coursepack.json"
if [[ -f "$task_coursepack" ]]; then
    cp "$task_coursepack" "$task_stage_app/Contents/Resources/coursepack.json"
else
    python3 "$task_root/Scripts/prepare-coursepack.py" "$task_root/Resources/coursepack.portable.json" "$task_stage_app/Contents/Resources/coursepack.json"
fi
cp "$task_root/Resources/AppIcon.icns" "$task_stage_app/Contents/Resources/AppIcon.icns"
cp -R "$task_root/Resources/StreamingEnglish" "$task_stage_app/Contents/Resources/"
cp -R "$task_root/Resources/Licenses" "$task_stage_app/Contents/Resources/"
cp "$task_vendor"/*.dylib "$task_stage_app/Contents/Frameworks/"
for task_library in "$task_stage_app/Contents/Frameworks/"*.dylib; do codesign --force --sign - "$task_library"; done
# Sign outside the Documents File Provider, which adds FinderInfo while signing.
codesign --force --sign - --identifier com.ming.lecturelens "$task_stage_app"
codesign --verify --deep --strict "$task_stage_app"
ditto -c -k --keepParent --norsrc --noextattr "$task_stage_app" "$task_archive"
if [[ ${1:-} == --install ]]; then
    task_install="/Applications/Lecture Lens.app"
    if [[ -e "$task_install" ]]; then
        task_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_install/Contents/Info.plist")
        [[ "$task_id" == com.ming.lecturelens ]] || { print 'Existing application has a different identifier; refusing to replace it.'; exit 1; }
    fi
    ditto --norsrc --noextattr "$task_stage_app" "$task_install"
    codesign --verify --deep --strict "$task_install"
    print "Installed: $task_install"
fi
print "Built: $task_archive"
