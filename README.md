
# Welcome to the DojoBits Toolbox repository!

Here you'll find various automation scripts and runbooks that we find valuable and want to share with the community. Please enjoy!



## k8s-up.sh

This script automates the creation of a single-node Kubernetes cluster on Ubuntu Linux using Cilium CNI.

### Usage

```shell
wget https://raw.githubusercontent.com/DojoBits/Toolbox/main/k8s-up.sh
```

Inspect the script:

```shell
less k8s-up.sh
```
Execute the script:

```shell
chmod +x k8s-up.sh
sudo ./k8s-up.sh
```

> [!Note]
> The script execution might take a minute or two.

When execution is finished, you'll see:

```shell
...
[INFO] Removing the control‑plane NoSchedule taint...
node/db-lab-110 untainted
[INFO] All done! 🎉

~$
```
