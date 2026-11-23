#!/usr/bin/env python3
"""Read plutil-converted project XML from stdin; select exactly one app Release.

The workflow retains macOS plutil for OpenStep conversion. XML pbxproj fixtures
exercise selection portably without implementing a second OpenStep parser.
"""
import plistlib
import sys


def project_version(objects):
    app, = [o for o in objects.values()
            if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'RClick']
    configs = objects[app['buildConfigurationList']]['buildConfigurations']
    release, = [objects[c] for c in configs if objects[c]['name'] == 'Release']
    version = release['buildSettings']['MARKETING_VERSION']
    if not isinstance(version, str) or not version:
        raise ValueError('missing string version')
    return version


if __name__ == '__main__':
    try:
        version = project_version(plistlib.loads(sys.stdin.buffer.read())['objects'])
    except (ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        sys.exit(f'Cannot determine app Release MARKETING_VERSION: {error}')
    print(version)
