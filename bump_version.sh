#!/bin/bash

# Default values
FORCE=0

# Parse arguments
while getopts "f" opt; do
  case $opt in
    f)
      FORCE=1
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

shift $((OPTIND-1))
NEW_VERSION=$1

if [ -z "$NEW_VERSION" ]; then
    echo "Usage: ./bump_version.sh [-f] <new_version_string>"
    echo "Example: ./bump_version.sh b1.0.1"
    exit 1
fi

# Check for uncommitted files
if ! git diff-index --quiet HEAD --; then
    if [ "$FORCE" -eq 0 ]; then
        echo "Error: There are uncommitted changes in the repository."
        echo "Please commit your changes first, or use the -f flag to force version bumping and tagging."
        exit 1
    else
        echo "Warning: Uncommitted changes detected, but proceeding due to -f flag."
    fi
fi

# Update the version in project.yml
# We match MARKETING_VERSION: "..." and replace the string inside quotes
sed -i '' -E "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$NEW_VERSION\"/" project.yml

# Re-generate Xcode project just to be sure (optional but good practice)
if command -v xcodegen &> /dev/null; then
    xcodegen generate
fi

# Commit the changes
git add project.yml
if [ -d "MWBClient.xcodeproj" ]; then
    git add MWBClient.xcodeproj
fi

git commit -m "Bump version to $NEW_VERSION"

# Create a git tag
git tag -a "$NEW_VERSION" -m "Release $NEW_VERSION"

echo "Version bumped to $NEW_VERSION"
echo "Commit created and tagged. You can now run 'git push origin main' and 'git push --tags'."
