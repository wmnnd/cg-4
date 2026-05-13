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

#ifndef CHECKABLE_COMBO_BOX_H
#define CHECKABLE_COMBO_BOX_H

#include <QComboBox>
#include <QStandardItemModel>
#include <QStringList>

class CheckableComboBox : public QComboBox
{
    Q_OBJECT
public:
    explicit CheckableComboBox(QWidget* parent = nullptr);

    void clearItems();
    void addCheckableItem(const QString& text, const QString& data);
    QStringList checkedData() const;
    void setPlaceholder(const QString& text);

signals:
    void selectionChanged();

protected:
    bool eventFilter(QObject* watched, QEvent* event) override;
    void hidePopup() override;

private:
    QStandardItemModel* itemModel;
    QString placeholderText;
    bool keepPopupOpen;
    void updateDisplayText();
};

#endif // CHECKABLE_COMBO_BOX_H
