# GitHub Actions Build Guide

This repository includes automated building and testing via GitHub Actions.

## What Gets Built

The workflow automatically:
1. ✅ Installs all build dependencies
2. ✅ Clones the latest uWSGI source code
3. ✅ Builds the uWSGI core
4. ✅ Compiles the Prometheus plugin
5. ✅ Installs promtool for validation
6. ✅ Runs the complete test suite
7. ✅ Uploads the compiled plugin as an artifact

## Automatic Triggers

The build runs automatically on:
- **Push** to `main` or `develop` branches
- **Pull requests** targeting `main` or `develop` branches

## Manual Builds

You can manually trigger a build with a custom uWSGI version:

1. Go to the **Actions** tab in GitHub
2. Click on **"Build and Test uWSGI Prometheus Plugin"**
3. Click **"Run workflow"**
4. Enter a uWSGI version (e.g., `2.0.23`) or leave as `latest`
5. Click **"Run workflow"**

## Downloading the Compiled Plugin

After a successful build:

1. Go to the **Actions** tab
2. Click on the completed workflow run
3. Scroll down to **Artifacts**
4. Download **metrics_prometheus-plugin.zip**
5. Extract to get `metrics_prometheus.so`

## Using the Downloaded Plugin

```bash
# Extract the artifact
unzip metrics_prometheus-plugin.zip

# Copy to your uWSGI plugins directory
sudo cp metrics_prometheus.so /usr/lib/uwsgi/plugins/

# Or use directly with absolute path
uwsgi --plugin /path/to/metrics_prometheus.so --ini your-config.ini
```

## Build Configuration

### Default Settings
- **uWSGI Version**: Latest from master branch
- **OS**: Ubuntu Latest
- **Python**: Python 3 (system default)
- **Promtool**: v2.48.1

### Customizing uWSGI Version

To build against a specific uWSGI version, use the manual workflow trigger with:
- Specific tags: `2.0.23`, `2.0.22`, etc.
- `latest` for the most recent code

## Build Matrix

Current matrix (can be expanded):
- Ubuntu latest
- Latest uWSGI (configurable)
- Full test suite with promtool validation

## Troubleshooting

### Build Failures

If the build fails:
1. Check the **Actions** tab for error logs
2. Look at the specific step that failed
3. Common issues:
   - uWSGI version doesn't exist (check valid tags at https://github.com/unbit/uwsgi/tags)
   - Test failures (check test output for details)

### Test Failures

The workflow will fail if tests don't pass. This ensures:
- Route handler mode works correctly
- Dedicated server mode works correctly
- Output is valid Prometheus format
- Metrics update properly

### Viewing Test Results

Test results are shown in the "Run plugin tests" step. You can:
- View detailed logs in the Actions tab
- See which specific tests passed/failed
- Check curl outputs and validation results

## Local Testing

To test the same build process locally:

```bash
# Install dependencies
sudo apt-get install build-essential python3 python3-dev libpcre3-dev \
                     libssl-dev zlib1g-dev libxml2-dev libyaml-dev

# Clone uWSGI
git clone https://github.com/unbit/uwsgi.git
cd uwsgi

# Copy plugin files
mkdir -p plugins/metrics_prometheus
cp /path/to/plugin.c plugins/metrics_prometheus/
cp /path/to/uwsgiplugin.py plugins/metrics_prometheus/
cp -r /path/to/t plugins/metrics_prometheus/

# Build
python3 uwsgiconfig.py --build core
python3 uwsgiconfig.py --plugin plugins/metrics_prometheus

# Run tests
plugins/metrics_prometheus/t/test.sh
```

## Badge

Add this to your README.md to show build status:

```markdown
![Build Status](https://github.com/YOUR_USERNAME/uwsgi-prometheus-exporter/actions/workflows/build.yml/badge.svg)
```

Replace `YOUR_USERNAME` with your GitHub username or organization name.
