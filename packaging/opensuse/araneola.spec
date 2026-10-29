#
# spec file for package araneola
#
# Copyright (c) 2026 SUSE LLC and contributors
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#

# Scheme sources plus a bash launcher: there is no compiled binary to
# debug, so the empty -debugsource package is skipped.
%global debug_package %{nil}

Name:           araneola
Version:        0.0.5
Release:        0
Summary:        Web crawler and sitemap generator written in Guile Scheme
License:        MIT
URL:            https://codeberg.org/jjba23/araneola
Source0:        %{name}-%{version}.tar.gz
BuildRequires:  pkgconfig(guile-3.0)
BuildRequires:  guile-lib
BuildRequires:  scriba
Requires:       guile
Requires:       bash
Requires:       coreutils
Requires:       guile-lib
Requires:       scriba

# NOTE: guile-lib is not packaged in openSUSE yet.  Build it first
# (from a devel project if needed) before this package.
# scriba is produced by the same packaging batch; build it first.

%description
Araneola crawls a web site from a starting URL, follows the links it finds
and writes an XML sitemap. It honours robots.txt rules, can stay on one host
and reports what it visited.

%prep
%autosetup -n %{name}-%{version}

# The launcher is a bash script; point it at the interpreter path
# openSUSE packages are expected to use instead of /usr/bin/env.
sed -i '1s|^#!%{_bindir}/env \(.*\)$|#!%{_bindir}/\1|' scripts/araneola

%build
# Nothing to build: the program is Scheme sources plus a launcher, and
# the sources are byte-compiled during %install so that they land in
# the interpreter's compiled-module directory.

%install
# Both directories are asked of Guile's pkg-config file rather than
# assumed, so the modules land where this distribution's Guile looks
# for them.
SITE_DIR="%{buildroot}$(pkg-config --variable=sitedir guile-3.0)"
CCACHE_DIR="%{buildroot}$(pkg-config --variable=siteccachedir guile-3.0)"

mkdir -p "$SITE_DIR/araneola" "$CCACHE_DIR/araneola"
cp -r src/araneola/. "$SITE_DIR/araneola/"

# Byte-compile every module so that loading it does not compile it
# again on first use.
find "$SITE_DIR/araneola" -name '*.scm' | while read -r scm_file; do
  rel_path="${scm_file#$SITE_DIR/}"
  go_file="$CCACHE_DIR/${rel_path%.scm}.go"
  mkdir -p "$(dirname "$go_file")"
  guild compile -L "$SITE_DIR" -o "$go_file" "$scm_file"
done

install -D -m 0755 scripts/araneola %{buildroot}%{_bindir}/araneola

# Upstream reads resources and the log helper from the generic
# share/resources and share/scripts; several of these packages
# would clash there, so both move under share/araneola/.
sed -i 's|share/resources|share/araneola/resources|g; s|share/scripts|share/araneola/scripts|g' %{buildroot}%{_bindir}/araneola

install -d "%{buildroot}%{_datadir}/araneola/resources"
cp -r resources/. "%{buildroot}%{_datadir}/araneola/resources/"
install -D -m 0644 scripts/log.bash "%{buildroot}%{_datadir}/araneola/scripts/log.bash"

%check
guile -L src -L . tests/run-tests.scm

%files
%license LICENSE
%doc README.org
%{_bindir}/araneola
%dir %{_datadir}/guile
%dir %{_datadir}/guile/site
%dir %{_datadir}/guile/site/3.0
%{_datadir}/guile/site/3.0/araneola
%dir %{_libdir}/guile
%dir %{_libdir}/guile/3.0
%dir %{_libdir}/guile/3.0/site-ccache
%{_libdir}/guile/3.0/site-ccache/araneola
%dir %{_datadir}/araneola
%{_datadir}/araneola/resources
%dir %{_datadir}/araneola/scripts
%{_datadir}/araneola/scripts/log.bash

%changelog
