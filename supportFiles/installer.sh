#!/bin/bash
installer=$(find / -name *_installer.sh | head -1)
basedir=$(dirname $installer)
installer=$(basename $installer)
cd $basedir
./$installer
#should not here
bash