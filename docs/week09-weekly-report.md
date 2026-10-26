# Wisualizer Week 9 Weekly Report

ZIP File Packaging

October 25, 2026

This week, I am focusing on extending the ZIP packaging workflow in Wisualizer so users can collect vector data, GLB models, and TXT notes into one file for importing and sharing. I forked the new repository and reviewed its existing desktop workspace, which already saves models, supported field data, images, and notes into ZIP packages. I will build on this editor to make preparing a complete dataset easier for the team.

I plan to add a file-selection workflow that imports existing TXT notes and includes additional data files while preserving their contents. I will investigate the vector formats used by the team, including EnSight exports and vector values stored in CSV or TXT files. The initial goal is to package these files reliably; format-specific interpretation will depend on their structure. I will also check how the new inputs fit the existing package manifest, model frames, and notes so the workflow remains compatible with Wisualizer.

To validate the feature, I will create a sample package containing a GLB model, vector data, and TXT notes, then check that the files remain intact after saving, reopening, and saving again. I will also test missing files, duplicate names, and save failures. Development will stay on my own branch in my fork without opening a pull request. Once the implementation is ready, I will provide the latest commit hash for review and integration.
