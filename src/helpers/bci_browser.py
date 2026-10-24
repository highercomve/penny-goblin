"""BCI entry point for the shared private download browser."""
from bank_download_browser import bank_url, main, run

LOGIN = "https://www.bci.cl/corporativo/banco-en-linea/personas"

if __name__ == "__main__":
    main("bci")
