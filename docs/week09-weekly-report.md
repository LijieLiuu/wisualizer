# Wisualizer Week 9 Weekly Report

ZIP File Packaging

October 25, 2026

This week, my focus is to extend Wisualizer's file-packaging workflow so users can combine vector data, GLB models, and TXT notes into a single ZIP for importing and sharing. These files often describe the same simulation, so keeping them together should make it easier to prepare a complete example and maintain the connection between a model and its supporting information. I have forked the new repository and reviewed its desktop editor as the starting point for this work.

The current editor already organizes model frames, supported EnSight field data, images, and notes into ZIP packages. It also creates a meta.json file that tells Wisualizer where the package contents are located. I plan to extend this structure with a clearer workflow for selecting and organizing additional input files. GLB files will continue to use the existing model import process, while TXT files can be imported as notes and other source files can be included as supporting data.

One part of the work will be investigating what the vector files contain and how they should be represented in a package. I will examine relevant EnSight exports and vector values stored in CSV or TXT files, including how positions, vector components, and time steps are recorded. SVG vector images are already supported by the editor. For scientific vector data, the initial packaging goal is to preserve the original files and their contents. Parsing or displaying those values will require a defined format and separate validation.

For the interface, I plan to make it easy to choose several files, review their roles in the package, and select where the ZIP will be saved. Importing TXT notes should handle text encoding clearly and let users decide how to combine the imported text with existing notes. The workflow should identify missing source files and duplicate names before saving. I will also check that file paths remain valid inside the archive, so a package can be moved to another computer without depending on the original folders.

Validation will use a sample package containing a GLB model, vector data, and TXT notes. I will compare the packaged files with their sources, reopen the ZIP in Wisualizer, and save it again to check that supported content and additional files are retained. Tests will also cover empty selections, unreadable files, duplicate names, and failed saves. The expected result is a practical way for the team to prepare complete datasets for demonstrations. Development will remain on my own branch in my fork without opening a pull request; once the implementation is ready, I will provide the latest commit hash for review and integration.
