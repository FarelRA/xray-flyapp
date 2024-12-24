#!/bin/sh

# Define repository owner and name
OWNER="fatedier"
REPO="frp"
API_URL="https://api.github.com/repos/$OWNER/$REPO/releases/latest"

# Function to extract the tarball URL from the JSON response
fetch_tarball_url() {
   curl -Ls "$1" | grep '"tarball_url":' | sed -E 's/.*"([^"]+)".*/\1/'
}

# Function to download and extract the tarball
download_and_extract_tarball() {
  curl -Ls "$1" | tar -xz --strip-components 1
}

# Fetch the latest tarball URL
echo "Fetching the latest tarball URL..."
tarball_url=$(fetch_tarball_url "$API_URL")

# Check if a valid tarball URL is found
if [ -z "$tarball_url" ]; then
  echo "Error: Failed to retrieve the tarball URL from the response."
  exit 1
fi

# Download and extract the tarball
echo "Downloading and extracting the tarball..."
download_and_extract_tarball "$tarball_url"

# Check if the download and extraction were successful
if [ $? -ne 0 ]; then
  echo "Error: Failed to download or extract the tarball."
  exit 1
fi

echo "Done!"