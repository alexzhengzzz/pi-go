#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
studio="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
export DEVECO_SDK_HOME="$studio/sdk"
export DEVECO_NODE_HOME="$studio/tools/node"
export JAVA_HOME="$studio/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:$DEVECO_NODE_HOME/bin:$PATH"
cd "$project_root/harmony"
"$studio/tools/ohpm/bin/ohpm" install --all
"$studio/tools/hvigor/bin/hvigorw" --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap --no-daemon
