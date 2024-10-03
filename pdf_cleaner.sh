#!/bin/bash -e

COMPR=60 # Compression for jpeg method

TEMPDIR="/tmp/pdfcleaner"

checkArgs() {
    if (( $1 < 2 )); then
        print_help
    fi
}

print_help() {
  NAME="$(basename "$0")"
cat <<HELP-MSG
Usage: $NAME SOURCE_PATH DEST_PATH [FORMAT]
The purpose of this script is to flatten PDF files by removing layers and metadata.
Optionally, it can convert text to images.

Mandatory arguments:
  SOURCE_PATH   Location of the PDF files.
  DEST_PATH     Location where new PDF files will be created.

Optional argument:
  FORMAT available options:
        - img_uncomp (default)  Convert to uncompressed images.
        - img_comp              Convert to compressed images. It may create image artifacts.
        - text                  Keep text.

Considerations:
 - img_uncomp and img_comp output files are bigger since there is no text, only images.

HELP-MSG
  exit
}

processArgs(){
    if [[ -d "$1" ]]; then
        SRC_DIR="$1"
    else
        echo "[ERROR] $1 is not a directory"
        echo
        print_help
    fi

    DESTDIR="$2"

    case $3 in
        img_comp)
            echo "Flattening and converting PDFs to jpeg images with $COMPR% compression"
            CONVERT_METHOD="img_comp"
            echo
            ;;
        text)
            echo "Flattening PDFs keeping text"
            CONVERT_METHOD="text"
            echo
            ;;
        *)
            echo "Default method. Flattening and converting PDFs to png images without compression"
            CONVERT_METHOD="img_uncomp"
            echo
            ;;
    esac
}
convert_using_compressed_images () {
    FILE_SRC="$1"
    FILE_DEST="$2"
    FILE_BASENAME="$3"
    # Convert pdf to images
    pdftoppm -q "$FILE_SRC" "${TEMPDIR}/${FILE_BASENAME}" -jpeg
    # Compress images
    mogrify -quality ${COMPR}% "${TEMPDIR}/${FILE_BASENAME}"*jpg
    # Convert images to pdf
    convert "${TEMPDIR}/${FILE_BASENAME}"*jpg "${FILE_DEST}"
}

convert_using_uncompressed_images () {
    FILE_SRC="$1"
    FILE_DEST="$2"
    FILE_BASENAME="$3"
    # Convert pdf to images
    pdftoppm -q "$FILE_SRC" "${TEMPDIR}/${FILE_BASENAME}" -png
    # Convert images to pdf
    convert "${TEMPDIR}/${FILE_BASENAME}"*png "${FILE_DEST}"
}

convert_keeping_text() {
    FILE_SRC="$1"
    FILE_DEST="$2"
    pdf2ps "${FILE_SRC}" - | ps2pdf - "${FILE_DEST}"
}

checkArgs $#
processArgs "$@"

mkdir -p "${TEMPDIR}" "${DESTDIR}"

for FILE_SRC in "${SRC_DIR}"/*pdf
do
    echo "Processing ${FILE_SRC}"
    FILE_BASENAME="$(basename -s'.pdf' "$FILE_SRC")"
    FILE_DEST="${DESTDIR}/${FILE_BASENAME}.pdf"

    case $CONVERT_METHOD in
        img_comp)
            convert_using_compressed_images "${FILE_SRC}" "${FILE_DEST}" "${FILE_BASENAME}"
            ;;
        text)
            convert_keeping_text "${FILE_SRC}" "${FILE_DEST}" "${FILE_BASENAME}"
            ;;
        *)
            convert_using_uncompressed_images "${FILE_SRC}" "${FILE_DEST}" "${FILE_BASENAME}"
            ;;
    esac
done
