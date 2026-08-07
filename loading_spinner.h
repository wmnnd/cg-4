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

#ifndef LOADING_SPINNER_H
#define LOADING_SPINNER_H

#include <QElapsedTimer>
#include <QWidget>

class QTimer;

// Self-contained replacement for the old WebEngine-rendered search spinner:
// the "lds-ellipsis" four-dot animation (CC0, loading.io) the search tab used
// to draw from HTML/CSS. Painted directly with QPainter so it needs no
// WebEngine, no GIF asset, and stays crisp at any DPI. Drop it on top of a
// widget (e.g. a view's viewport), show() it while loading and hide() when
// done — it only animates while visible.
class LoadingSpinner : public QWidget
{
    Q_OBJECT

public:
    explicit LoadingSpinner(QWidget* parent = nullptr);

protected:
    void paintEvent(QPaintEvent* event) override;
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    QTimer* animationTimer;
    QElapsedTimer clock;
};

#endif // LOADING_SPINNER_H
