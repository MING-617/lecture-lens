#!/bin/zsh
set -euo pipefail
task_root=${0:A:h:h}
task_vendor="$task_root/Vendor/SherpaOnnx"
mkdir -p "$task_root/.cache/tests"
task_results=$(mktemp -d "$task_root/.cache/tests/run.XXXXXX")
task_native=("$task_root/Sources/Core.swift" "$task_root/Sources/StreamingDecoder.swift" "$task_root/Sources/VoiceActivity.swift" "$task_root/Sources/TranscriptArchive.swift" "$task_root/Sources/SpeechSession.swift")
task_flags=(-O -assert-config Debug -swift-version 5 -parse-as-library -target arm64-apple-macos26.0)
task_link=(-import-objc-header "$task_vendor/c-api.h" -L "$task_vendor" -l sherpa-onnx-c-api -Xlinker -rpath -Xlinker "$task_vendor")
xcrun swiftc "${task_flags[@]}" "$task_root/Sources/Core.swift" "$task_root/Tests/CoreTests.swift" -o "$task_results/core-tests"
"$task_results/core-tests" "$task_root/Resources/coursepack.portable.json"
xcrun swiftc "${task_flags[@]}" "${task_link[@]}" "${task_native[@]}" "$task_root/Sources/AppModel.swift" "$task_root/Tests/SessionTests.swift" -o "$task_results/session-tests"
"$task_results/session-tests" "$task_results/transcripts"
xcrun swiftc "${task_flags[@]}" "${task_link[@]}" "${task_native[@]}" "$task_root/Tests/AudioQueueTests.swift" -o "$task_results/queue-tests"
"$task_results/queue-tests" "$task_root/Resources/StreamingEnglish"
print "Tests passed. Local results: $task_results"
