import AppKit

// The bar crest, embedded so the binary needs no asset path at runtime (launchd
// services cannot read the TCC-protected repo). This is assets/yorha-icon-dark.png
// byte for byte; the light crest has the same alpha, so the bar uses this as a
// mask and tints it from the palette. A test keeps it in sync with the asset.
enum BarCrest {
    static let png = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAB8AAAAkCAYAAABxE+FXAAAACXBIWXMAAAABAAAAAQBPJcTWAAAETUlEQVR4nLWX
        e6ifcxzH37vxw5y5jWOM2qxZWvyhESaXjS25NSykrBRDoqQk/pBLksQfGEu5ZmFmDavdkLa2JsTkEo7LhszYzGWz
        s+P96vN5dn4dv8vza8++9arfeZ7nfN/fz/15Bi198gqVXENMzfzZ4hnu/2t6y2w4tKyy1wRzrnmoxTOzzBrzftXi
        J5gxZrDZ2eD+IHOyWb8nxI83W0yX+b3Bfa4fmocrtToRH2/eMyPqxI8y3+XvbnOg2WGGKWJfiTjWHGk2m33z2nBz
        j7lR4RGs3sf8o/7Eq0SczQ5SZPreeY0E7E4QH6mwuBD/oypxLBqeGxf/g/i2PBTrAEU5bqs7YCXiNfW7skgo4v13
        nVBX3ttedt+y4gjg0h114gcrrBySf5MLlFtvPluZ+F75bF+Ks/l+KTQ0qeWzO+sOVIn4sBTtzYNco7C0iC9/j9hT
        4sXCOkpqhiL51qfoZeYnhduJ/fYqxcn2xxVdbpOi5A4zPXkYrF1ptpqzzDtViR9hXldYudjcZx4zU827is73obnX
        PGwuNjeZSeaH3RXfaM7IzS9RTK4LFMlHDpALeOFac6f5SpEDv7bbuIw4SfW5wvIT8/dqRdmNNi+bo81HivDQ6z8u
        sW9b8XEK675WJBKjckoehIT73pxnlpuz8wBd+b/duX9T17cSH6tIog3mQvOcuU3RVmmlzHbKDat/VAwequEJM8os
        UHiGGf9tp+KXKlz7iWKUXm7eUpRVb15jqt2hSEq8tEgRa8LCG83hZpqZ04k4rts/LSKOtNIpacmnisZSNBV+0+1I
        tPF5DZdT8z35HGwuI36KeVGROFiI294wE83pijrGG0vyPiV1flqON5aahYqeQLP5LPdkv3WtxGeaBxUZvNbcqogr
        lv1sXjXXmfn5+zSFqycrwjRP/bN/VHrjZnO/ohy5t+v9rl6c+r3S3K1IslpaeYh5wfyiqF/qmmT8RjFij1Uk5NTc
        5ynFiwUe60nhR9PqdXmwJYU4g+Jqc5x5IIUpjyJGuJbkIZv78to55k3zUlpUCBd74vYvFfP+BsWLCF461VxvjjFz
        eZCJ9bZ5WpHdAxcZPdvcYj4wy9IqOhquv93cpejnCJykKLPpivCw6PmLE8JIYtYQZ0h80UBU+eDMdCWuIuup/VXm
        InOm4iNiTnqFUUobfkQRJkK2ccCef6URbTsclgzOzcflAVhk/uS0lmuErOgHDJ25in4wpoH4rtVOfEZuhgUrFH2e
        RdlsyYNRwxvyOgnIRHtFURXzWm3eSpxNcTsuouzqPxD5aCChaDAk06a6eyToVeYZhedWqsnHZStxmgR1ysz+X3dS
        TC66ILEe+OZCgpHVzAMScHkn4rRGWumzavxdxqJZEPdmHwc0JSoE61eov0zbirNeU2Rms0U4+GRumlCKptJworUS
        72sjzKI8eXf7rc1zWzsVL7NIMjpZu0M2XbsjTlY/rwaxLLv+A4fB+lyRuyT+AAAAAElFTkSuQmCC
        """, options: .ignoreUnknownCharacters)!

    static let image: CGImage? = NSBitmapImageRep(data: png)?.cgImage
}
