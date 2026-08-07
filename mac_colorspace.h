/*
    ClipGrab³
    Copyright (C) The ClipGrab Project
    http://clipgrab.de
    feedback [at] clipgrab [dot] de

    This file is part of ClipGrab.
    ClipGrab is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    ClipGrab is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with ClipGrab.  If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef MAC_COLORSPACE_H
#define MAC_COLORSPACE_H

#include <QtGlobal>

class QWidget;

// Tag a top-level widget's native window as sRGB so macOS colour-manages its
// contents to the display's gamut — matching how web browsers render sRGB
// colours. Without this, Qt sends raw sRGB component values straight to
// wide-gamut (Display P3) panels with no conversion, which oversaturates
// colours (e.g. rgb(255,51,133) reads as a far brighter pink than in a
// browser). No-op on non-macOS platforms.
#if defined(Q_OS_MAC)
void setWindowSRGBColorSpace(QWidget* widget);

// Install an application-wide hook that tags every top-level window as sRGB
// the moment it is shown (see setWindowSRGBColorSpace). Call once, right after
// the QApplication is constructed, so the main window and every dialog get
// colour-managed consistently. No-op on non-macOS platforms.
void installAppWideSRGBColorSpace();
#else
inline void setWindowSRGBColorSpace(QWidget*) {}
inline void installAppWideSRGBColorSpace() {}
#endif

#endif // MAC_COLORSPACE_H
