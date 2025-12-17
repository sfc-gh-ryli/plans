set -ex


chmod -R 777 sysroot 
rm -rf sysroot

x86_64_dirs=(
    "/usr/include"
    "/usr/local/include/c++"
    "/usr/local/include/x86_64-unknown-linux-gnu/c++"
    "/usr/lib64"
    "/lib64"
    "/opt/rh/devtoolset-11/root/usr/lib/gcc/x86_64-redhat-linux/11"
)

aarch64_dirs=(
    "/usr/include"
    "/usr/local/include/c++/11"
    "/usr/local/include/x86_64-unknown-linux-gnu/c++"
    "/usr/lib64"
    "/lib64"
    "/opt/rh/devtoolset-10/root/usr/lib/gcc/aarch64-redhat-linux/10"
)

if uname -m | grep -q "x86_64"; then
    dirs="${x86_64_dirs[@]}"
else
    dirs="${aarch64_dirs[@]}"
fi

for from in "${dirs[@]}"; do
    to="$(dirname $from)"
    mkdir -p "sysroot$to"
    cp -r  "$from" "sysroot$to"
done

tar -czvf "sysroot-$(date "+%Y%m%d%H%M%S").tar.gz" sysroot

echo "OK"