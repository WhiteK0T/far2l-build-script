# Copyright 2026 WhiteK0T
# Distributed under the terms of the GNU General Public License v2

EAPI=8

# The plugin embeds CPython via its C API: no PyPy or free-threaded builds
PYTHON_COMPAT=( python3_{12..14} )
WX_GTK_VER="3.2-gtk3"

inherit cmake optfeature python-single-r1 wxwidgets xdg

DESCRIPTION="Linux port of FAR Manager v2: console and GUI file manager"
HOMEPAGE="https://github.com/elfmz/far2l"

if [[ ${PV} == 9999 ]]; then
	inherit git-r3
	EGIT_REPO_URI="https://github.com/elfmz/far2l.git"
else
	SRC_URI="https://github.com/elfmz/far2l/archive/refs/tags/v_${PV}.tar.gz -> ${P}.tar.gz"
	S="${WORKDIR}/${PN}-v_${PV}"
	KEYWORDS="~amd64"
fi

# GPL-2: far2l; LGPL-2.1+: bundled libmtp and 7-Zip code in arclite;
# MIT: bundled Colorer library; unRAR: bundled unrar sources in multiarc
LICENSE="GPL-2 LGPL-2.1+ MIT unRAR"
SLOT="0"
IUSE="+mtp +nfs python +samba sdl +ssh +ssl +uchardet +webdav +wxwidgets +X"
REQUIRED_USE="python? ( ${PYTHON_REQUIRED_USE} )"

DEPEND="
	app-arch/libarchive:=
	dev-libs/libxml2:=
	mtp? ( virtual/libusb:1 )
	nfs? ( net-fs/libnfs:= )
	python? ( ${PYTHON_DEPS} )
	samba? ( net-fs/samba )
	sdl? (
		media-libs/fontconfig
		media-libs/freetype
		media-libs/harfbuzz:=
		media-libs/libsdl2
	)
	ssh? ( net-libs/libssh:=[sftp] )
	ssl? ( dev-libs/openssl:= )
	uchardet? ( app-i18n/uchardet )
	webdav? ( net-libs/neon:= )
	wxwidgets? ( x11-libs/wxGTK:${WX_GTK_VER}=[X] )
	X? (
		x11-libs/libX11
		x11-libs/libXi
	)
"
RDEPEND="
	${DEPEND}
	python? ( $(python_gen_cond_dep 'dev-python/cffi[${PYTHON_USEDEP}]') )
"
BDEPEND="virtual/pkgconfig"

pkg_setup() {
	use python && python-single-r1_pkg_setup
}

src_configure() {
	local aws=no
	use ssl && use webdav && aws=yes

	local mycmakeargs=(
		-DUSEWX=$(usex wxwidgets)
		-DUSESDL=$(usex sdl)
		-DTTYX=$(usex X)
		-DTTYXI=$(usex X)
		-DUSEUCD=$(usex uchardet)
		-DMTP=$(usex mtp)
		-DNR_SFTP=$(usex ssh)
		-DNR_SMB=$(usex samba)
		-DNR_NFS=$(usex nfs)
		-DNR_WEBDAV=$(usex webdav)
		-DNR_OPENSSL=$(usex ssl)
		-DNR_AWS=${aws}
		-DPYTHON=$(usex python)
		$(cmake_use_find_package ssh LibSSH)
		$(cmake_use_find_package samba Libsmbclient)
		$(cmake_use_find_package nfs LibNfs)
		$(cmake_use_find_package webdav LibNEON)
		$(cmake_use_find_package ssl OpenSSL)
	)

	if use python; then
		# The plugin dlopen()s libpython of the selected implementation
		mycmakeargs+=( -DPython3_EXECUTABLE="${PYTHON}" )
	else
		# Python is only probed to generate AppStream metainfo; avoid automagic
		mycmakeargs+=( -DCMAKE_DISABLE_FIND_PACKAGE_Python3=ON )
	fi

	if use wxwidgets; then
		setup-wxwidgets
		mycmakeargs+=( -DwxWidgets_CONFIG_EXECUTABLE="${WX_CONFIG}" )
	fi

	cmake_src_configure
}

src_install() {
	cmake_src_install

	# Plugin modules live outside site-packages, byte-compile them here
	use python && python_optimize "${ED}"/usr/lib/far2l/Plugins/python
}

pkg_postinst() {
	xdg_pkg_postinst

	optfeature "archive handling in multiarc and arclite plugins" app-arch/7zip app-arch/p7zip
	optfeature "clipboard access in terminal mode without X support" x11-misc/xclip x11-misc/xsel

	if use python; then
		elog "Put your Python plugins into ~/.config/far2l/plugins/python"
		elog "Examples and docs: ${EPREFIX}/usr/share/far2l/Plugins/python/plugins"
	fi

	if use sdl; then
		elog "To start far2l with the SDL backend, run: far2l --SDL"
	fi
}
