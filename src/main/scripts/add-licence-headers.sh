#! /bin/bash
# Copyright (c) 2016 TripAdvisor
# Licensed under the PostgreSQL License
# https://opensource.org/licenses/postgresql

HEADER_FILE=$(dirname $0)/license_header.txt

for file in $(find $1 -type f) ; do
  if ! grep -qi copyright $file; then
    COMMENT_CHAR=''
    case $file in
    *java|*gradle)
      COMMENT_CHAR='//'
      ;;
    *sql)
      COMMENT_CHAR='--'
      ;;
    *.sh)
      COMMENT_CHAR='#'
      ;;
    esac
    if [[ "$COMMENT_CHAR" != "" ]]; then
      awk 'NR == 1 && /^#!/' $file >> ${file}.tmp
      awk -v comment_char="$COMMENT_CHAR" '{ print comment_char " " $0 }' $HEADER_FILE >> ${file}.tmp
      awk '!(NR == 1 && /^#!/)' $file >> ${file}.tmp
      rm $file
      mv ${file}.tmp ${file}
    else
      echo "Skipping $file due to file type"
    fi
  fi
done

