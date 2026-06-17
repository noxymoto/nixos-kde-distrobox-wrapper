# nixos-kde-distrobox-wrapper
You can use and modify this script to boot into persistent/non-persistent kde windows (launched inside of another wayland compositor) with a distrobox of your choice acting as the backend. 

Please note the following:
- The script works best with RPM based containers (probably because distrobox is a fork of toolbx, written by redhat)
- For the kubuntu test on the reddit, I used a ublue-os container, which worked well
- This method is inherently hacky; I'm pretty sure KDE doesn't support this, though wayland/distrobox/strong primitives make it fully functional in most cases
- I envision using this for either ephemeral sessions or persistent KDE "sub-distros" that can both borrow from your global nixpkgs (those work well in all the containers) and allow you to install and use packages from the container
- Feel free to modify the scripts to your liking. They were vibe coded based on a distrobox experiment and tweaked till they worked. You could probably make it work without the launcher by just tweaking the distrobox primitives.

