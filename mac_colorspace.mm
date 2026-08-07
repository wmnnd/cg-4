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

#include "mac_colorspace.h"

#include <QApplication>
#include <QEvent>
#include <QWidget>

#import <AppKit/AppKit.h>

void setWindowSRGBColorSpace(QWidget* widget)
{
    if (!widget) {
        return;
    }
    // winId() realises the native NSView; for a top-level widget that view is
    // the content view of an NSWindow, and the window's colorSpace is what the
    // compositor uses when converting the backing store to the display.
    NSView* view = reinterpret_cast<NSView*>(widget->winId());
    NSWindow* window = view ? view.window : nil;
    if (window) {
        window.colorSpace = [NSColorSpace sRGBColorSpace];
    }
}

namespace {

// Tags each top-level window as sRGB the moment it is shown. Overriding only
// the eventFilter virtual needs no Q_OBJECT / moc.
class SRGBWindowFilter : public QObject
{
public:
    using QObject::QObject;

    bool eventFilter(QObject* obj, QEvent* event) override
    {
        if (event->type() == QEvent::Show) {
            QWidget* w = qobject_cast<QWidget*>(obj);
            if (w && w->isWindow()) {
                setWindowSRGBColorSpace(w);
            }
        }
        return QObject::eventFilter(obj, event);
    }
};

} // namespace

void installAppWideSRGBColorSpace()
{
    if (!qApp) {
        return;
    }
    qApp->installEventFilter(new SRGBWindowFilter(qApp));
    // Cover any top-level windows that already exist when this is called.
    const QList<QWidget*> tops = QApplication::topLevelWidgets();
    for (QWidget* w : tops) {
        if (w->isWindow() && w->windowHandle()) {
            setWindowSRGBColorSpace(w);
        }
    }
}
