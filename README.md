# What is Coco-Patcher ?
A small software through which one can run accessibility related scripts in Accessible-Coconut OS.


# Updating Coco-Patcher

Follow these steps to update, build, and publish a new version of Coco-Patcher to the Launchpad PPA.

## Prerequisites

Install the required packaging tools:

```bash
sudo apt-get install debhelper devscripts
```

## Steps

### 1. Create a Packaging Workspace

```bash
mkdir packaging
cd packaging
```

### 2. Clone the Repository

```bash
git clone https://github.com/zendalona/coco-patcher.git
cd coco-patcher
```

### 3. Switch to the Target Branch

```bash
git checkout jammy
```

### 4. Update the Source Code

Add or update the required scripts and make any necessary changes.

### 5. Update the Debian Changelog

Use `dch` to create a new changelog entry and update the package version:

```bash
dch
```

### 6. Commit and Push Changes

Commit your changes and push them to GitHub:

```bash
git add .
git commit -m "Update package version"
git push origin jammy
```

### 7. Build the Source Package

Build the source package using your GPG key:

```bash
debuild -S -kYOURKEY
```

Replace `YOURKEY` with your GPG key ID.

### 8. Return to the Workspace Directory

```bash
cd ..
```

### 9. Upload the Package to Launchpad PPA

Upload the generated source package to the Coco-Patcher PPA:

```bash
dput ppa:nalin-x-linux/coco-patcher-jammy <source-package>.changes
```

Replace `<source-package>.changes` with the generated `.changes` file, for example:

```bash
dput ppa:nalin-x-linux/coco-patcher-jammy coco-patcher_0.2.1.1_source.changes
```

## Notes

- Always update the Debian changelog before building the package.
- Ensure all changes are committed and pushed before uploading to the PPA.
- Verify that the correct branch is checked out before making changes.
- Make sure your GPG key is registered with Launchpad and available locally.
