import AppKit
import CoreImage.CIFilterBuiltins
import Foundation

let input = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let filter = CIFilter.qrCodeGenerator()
filter.message = Data(input.utf8)
filter.correctionLevel = "M"
let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
let bitmap = NSBitmapImageRep(cgImage: CIContext().createCGImage(image, from: image.extent)!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
