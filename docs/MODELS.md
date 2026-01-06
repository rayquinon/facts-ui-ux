Migration and storage guidance for large model files

This project includes several large ONNX model files which inflate the repository size.

Recommended options:

- Git LFS
  - Track `assets/models/*.onnx` and `weights/*.onnx` using Git LFS (a `.gitattributes` file is included).
  - Install Git LFS (`git lfs install`) and migrate existing files into LFS with `git lfs migrate import --include="assets/models/*.onnx,weights/*.onnx"`.

- Cloud Storage
  - Upload models to Firebase Storage / S3 and download them at app startup or the first run.
  - Advantages: smaller repo, faster CI, easier model rotation.

Loading at runtime example (pseudo):

1. Upload models to a storage bucket.
2. At app start, check local cache; if missing, download the file and save to app-specific storage.
3. Load the ONNX model from the local path.

If you want, I can add a small helper to download models from Firebase Storage at runtime and adjust asset references.
