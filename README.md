# gr33n37-ip-changer

Bash script that uses Tor to change your IP at specified intervals.

![gp](https://github.com/gr33n37/gr33n37-ip-changer/assets/30112537/34e1c4e2-ec79-4ef3-b0a2-e99eee48bb4b)

## Installation

You can either `git clone` the repository or `curl` the Bash script.

Using `git clone`:

```shell
git clone https://github.com/gr33n37/gr33n37-ip-changer.git
cd gr33n37-ip-changer
```

Using `curl`:

```shell
curl -O 'https://raw.githubusercontent.com/gr33n37/gr33n37-ip-changer/main/ip-changer.sh'
chmod +x ip-changer.sh
```

## Usage

Run the script with root privileges:

```shell
sudo ./ip-changer.sh
```

First, enter how long you want to stay on one server before changing the IP.
Then, enter how many times to change the IP. Enter 0 for unlimited changes.
