#!/bin/sh

pip uninstall -y md2zhihu

cp setup.py ..
(
cd ..
rm dist/*
python3 setup.py sdist bdist_wheel
pip3 install dist/*.tar.gz
)

PYTHONPATH="$(cd ..; pwd)" pytest -x
