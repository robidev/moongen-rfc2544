#!/bin/bash

cd $1

for file in *.tikz; do pdflatex $file; done

pdflatex --output-directory=.. *.tex


