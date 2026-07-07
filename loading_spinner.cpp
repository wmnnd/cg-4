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

#include "loading_spinner.h"

#include <QPainter>
#include <QTimer>

namespace {

// One grow→slide→shrink cycle. The reference APNG plays four such cycles over
// its 2.22s loop, i.e. ~555ms each.
constexpr int kPeriodMs = 555;

// ClipGrab cyan (#00b4de) — the dot colour the CSS version used.
const QColor kDotColor(0x00, 0xb4, 0xde);

// The CSS dots eased with timing-function cubic-bezier(0, 1, 1, 0). For those
// control points P1=(0,1), P2=(1,0) the parametric Bézier reduces to
//   x(s) = 3s² − 2s³   (monotonic on [0,1]; this is smoothstep)
//   y(s) = 3s − 6s² + 4s³
// so we recover s from x(s)=t by bisection, then evaluate y(s) as the eased
// progress. 24 steps put us well under a pixel of error.
double easeProgress(double t)
{
    double lo = 0.0, hi = 1.0, s = 0.0;
    for (int i = 0; i < 24; ++i) {
        s = 0.5 * (lo + hi);
        const double x = (3.0 - 2.0 * s) * s * s;   // 3s² − 2s³
        if (x < t) lo = s; else hi = s;
    }
    return ((4.0 * s - 6.0) * s + 3.0) * s;          // 4s³ − 6s² + 3s
}

} // namespace

LoadingSpinner::LoadingSpinner(QWidget* parent)
    : QWidget(parent), animationTimer(new QTimer(this))
{
    // The spinner is a passive overlay — let clicks reach the view beneath it.
    setAttribute(Qt::WA_TransparentForMouseEvents);
    animationTimer->setInterval(1000 / 60);   // ~60 fps
    connect(animationTimer, &QTimer::timeout, this, [this] { update(); });
}

void LoadingSpinner::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    clock.restart();
    animationTimer->start();
}

void LoadingSpinner::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    animationTimer->stop();   // idle while hidden — no wasted repaints
}

void LoadingSpinner::paintEvent(QPaintEvent* /*event*/)
{
    const double t = (clock.isValid() ? clock.elapsed() % kPeriodMs : 0) / double(kPeriodMs);
    const double e = easeProgress(t);

    // lds-ellipsis at the reference APNG's proportions (200px box): dot radius
    // 20 with three rest positions 68px apart. One dot grows in at the left,
    // the middle two slide one step right, the last shrinks out at the right;
    // the grow/shrink pair straddles the loop seam so the motion is seamless.
    const double cx = width() / 2.0;
    const double cy = height() / 2.0;
    const double f = qMin(1.0, width() / 200.0);   // shrink to fit only if narrow
    if (f <= 0.0) return;
    const double R = 20.0 * f;
    const double step = 68.0 * f;

    struct Dot { double x, scale; };
    const Dot dots[] = {
        { cx - step,             e       },   // grow in at the left
        { cx - step * (1.0 - e), 1.0     },   // slide left → middle
        { cx + step * e,         1.0     },   // slide middle → right
        { cx + step,             1.0 - e },   // shrink out at the right
    };

    QPainter p(this);
    // Clear the previous frame (child widgets aren't auto-erased, so the moving
    // dots would otherwise smear); Base matches the empty results list beneath.
    p.fillRect(rect(), palette().color(QPalette::Base));
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setPen(Qt::NoPen);
    p.setBrush(kDotColor);
    for (const Dot& d : dots) {
        const double rr = R * d.scale;
        if (rr > 0.05) p.drawEllipse(QPointF(d.x, cy), rr, rr);
    }
}
