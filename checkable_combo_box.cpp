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

#include "checkable_combo_box.h"

#include <QAbstractItemView>
#include <QEvent>
#include <QLineEdit>
#include <QMouseEvent>
#include <QStandardItem>

CheckableComboBox::CheckableComboBox(QWidget* parent)
    : QComboBox(parent),
      itemModel(new QStandardItemModel(this)),
      keepPopupOpen(false)
{
    setModel(itemModel);
    setEditable(true);
    lineEdit()->setReadOnly(true);
    lineEdit()->installEventFilter(this);
    view()->viewport()->installEventFilter(this);

    connect(itemModel, &QStandardItemModel::dataChanged, this,
            [this](const QModelIndex&, const QModelIndex&, const QList<int>& roles) {
        if (roles.isEmpty() || roles.contains(Qt::CheckStateRole)) {
            updateDisplayText();
            emit selectionChanged();
        }
    });

    updateDisplayText();
}

void CheckableComboBox::setPlaceholder(const QString& text)
{
    placeholderText = text;
    updateDisplayText();
}

void CheckableComboBox::clearItems()
{
    itemModel->clear();
    updateDisplayText();
}

void CheckableComboBox::addCheckableItem(const QString& text, const QString& data)
{
    QStandardItem* item = new QStandardItem(text);
    item->setFlags(Qt::ItemIsUserCheckable | Qt::ItemIsEnabled | Qt::ItemIsSelectable);
    item->setData(Qt::Unchecked, Qt::CheckStateRole);
    item->setData(data, Qt::UserRole);
    itemModel->appendRow(item);
    updateDisplayText();
}

QStringList CheckableComboBox::checkedData() const
{
    QStringList result;
    for (int i = 0; i < itemModel->rowCount(); ++i) {
        QStandardItem* item = itemModel->item(i);
        if (item && item->checkState() == Qt::Checked) {
            result << item->data(Qt::UserRole).toString();
        }
    }
    return result;
}

void CheckableComboBox::updateDisplayText()
{
    QStringList names;
    for (int i = 0; i < itemModel->rowCount(); ++i) {
        QStandardItem* item = itemModel->item(i);
        if (item && item->checkState() == Qt::Checked) {
            names << item->text();
        }
    }
    lineEdit()->setText(names.isEmpty() ? placeholderText : names.join(", "));
}

bool CheckableComboBox::eventFilter(QObject* watched, QEvent* event)
{
    if (watched == view()->viewport()) {
        if (event->type() == QEvent::MouseButtonRelease) {
            QMouseEvent* mouseEvent = static_cast<QMouseEvent*>(event);
            QModelIndex index = view()->indexAt(mouseEvent->pos());
            if (index.isValid()) {
                QStandardItem* item = itemModel->itemFromIndex(index);
                if (item) {
                    item->setCheckState(item->checkState() == Qt::Checked
                                        ? Qt::Unchecked
                                        : Qt::Checked);
                }
                keepPopupOpen = true;
                return true;
            }
        }
    } else if (watched == lineEdit()) {
        if (event->type() == QEvent::MouseButtonPress) {
            showPopup();
            return true;
        }
    }
    return QComboBox::eventFilter(watched, event);
}

void CheckableComboBox::hidePopup()
{
    if (keepPopupOpen) {
        keepPopupOpen = false;
        return;
    }
    QComboBox::hidePopup();
}
