#!/usr/bin/ruby
# These methods allow for the encoding and decoding of USPS' new Intelligent Mail Barcode

require 'yaml'

class RoutingCode
  attr_accessor :zip, :plus4, :deliveryPoint
  
  def initialize( *routingCode )
    routingCode.flatten!
    #puts y routingCode
    if routingCode.length == 1 and routingCode.first.is_a? String then
      # Check if it was given as a string and parse accoringly
      routingCode = routingCode.first.gsub /[\D]/, ''
      raise ArgumentError, "if delivery point is given as a string, it must be 5, 9, or 11 digits, after being stripped of non-digits" unless [5,9,11].include? routingCode.length
      routingCode = /^(\d{5})(?:(\d{4})(\d{2})?)?$/.match(routingCode).to_a[1..-1]
    end
    routingCode = routingCode.compact.map{ |el| el.to_i }
    @routingCode = routingCode
    @zip, @plus4, @deliveryPoint = routingCode
  end
  
  def to_a
    @routingCode
  end
  
  def to_i
    if @zip then
      if @plus4 then
        if @deliveryPoint
          @zip * 1000000 + @plus4 * 100 + @deliveryPoint + 1000100001
        else
          @zip * 10000 + @plus4 + 100001
        end
      else
        @zip + 1
      end
    else
      0
    end
  end
end

class IntelligentMailBarcode
  attr_accessor :barcodeId, :serviceType, :mailerId, :serialNumber, :deliveryPoint
  attr_accessor :binaryData, :codewords, :frameCheckSequence, :characters, :barcode
  
  constants = File.open( 'USPS.yml' ) { |yf| YAML::load( yf ) }
  Characters = constants[:characters]
  Mapping = constants[:mapping]

  # Define a common width for field labels as it prints each chunk of the encoding process
  LabelWidth = 32

  def initialize( barcodeId, serviceType, mailerId, serialNumber, *deliveryPoint )
    @barcodeId = barcodeId.to_i
    @serviceType = serviceType.to_i
    @mailerId = mailerId.to_i
    @serialNumber = serialNumber.to_i
    if deliveryPoint.first.is_a? RoutingCode then
      @deliveryPoint = deliveryPoint.first
    else
      @deliveryPoint = RoutingCode.new deliveryPoint
    end

    # validate
    raise ArgumentError, "barcodeId must exist within 0-94 and the LS digit must be 0-4" unless ((0..94) === @barcodeId) and ((0..4) === @barcodeId % 10)
    raise ArgumentError, "serviceType must exist within 000-999" unless ((0..999) === @serviceType) 
    @trackingCode = @serviceType
    case @mailerId
    when 0...899999
      raise ArgumentError, "serialNumber must exist within 000000000-999999999" unless ((0..999999999) === @serialNumber)
      @trackingCode = @trackingCode * (10**6) + @mailerId
      @trackingCode = @trackingCode * (10**9) + @serialNumber      
    when 900000000...999999999
      raise ArgumentError, "serialNumber must exist within 000000-999999" unless ((0..999999) === @serialNumber)
      @trackingCode = @trackingCode * (10**9) + @mailerId
      @trackingCode = @trackingCode * (10**6) + @serialNumber
    else
      raise ArgumentError, "mailerId must exist within either 000000-899999 or 900000000-999999999"
    end    
    encode
    
  end
  
  def to_i 
    barcode = 0
    @barcode.each do |bar|
      barcode <<= 2
      barcode += bar
    end
    return barcode
  end
  
  def to_s
    @barcode.map{|bar| "TDAF"[bar] }.join
  end
  
  def draw
    ascenders = ""
    descenders = ""
    trackers = "|" * 65
    @barcode.each do |bar|
      ascenders = ascenders + (bar[1] == 1 ? "|" : " ")
      descenders = descenders + (bar[0] == 1 ? "|" : " ")
    end
    puts ascenders + "\n" + trackers + "\n" + descenders
  end
  
  private
  
  def encode
    # Construct the "Binary Data"
    @binaryData = ((@deliveryPoint.to_i * 10 + @barcodeId / 10) * 5 + @barcodeId % 10) * 10**18 + @trackingCode
    #puts "Binary Data:".ljust(LabelWidth, " ") + @binaryData.to_hex(26).group(2, " ").rjust(65, " ")
    
    # Construct 11-bit CRC FCS
    @frameCheckSequence = crc
    #puts "Frame Check Sequence:".ljust(LabelWidth, " ") + @frameCheckSequence.to_hex(3).rjust(65, " ")
    
    # Construct Code words
    @codewords = Array.new 10
    data, @codewords[9] = @binaryData.divmod 636
    data, @codewords[8] = data.divmod 1365
    data, @codewords[7] = data.divmod 1365
    data, @codewords[6] = data.divmod 1365
    data, @codewords[5] = data.divmod 1365
    data, @codewords[4] = data.divmod 1365
    data, @codewords[3] = data.divmod 1365
    data, @codewords[2] = data.divmod 1365
    data, @codewords[1] = data.divmod 1365
          @codewords[0] = data
    #puts "Codewords: ".ljust(LabelWidth, " ") + @codewords.join(" ").rjust(65, " ")
    
    # add orientation information to J
    @codewords[9] *= 2
    #puts "Codewords with Orientation in J:".ljust(LabelWidth, " ") + @codewords.join(" ").rjust(65, " ")
    
    #add FCS bit to A
    @codewords[0] += 659 if @frameCheckSequence[10] == 1
    #puts "Codewords with FCS in A:".ljust(LabelWidth, " ") + @codewords.join(" ").rjust(65, " ")
    
    # Translate Codewords to Characters
    @characters = Array.new
    @characters = @codewords.map { |codeword| Characters[codeword] }
    #puts "Characters:".ljust(LabelWidth, " ") + @characters.map{|character| character.to_hex(4) }.join(" ").rjust(65, " ")
    
    # Negate each character if its corresponding frameCheckSequence bit is on
    @characters.each_index do |i|
      @characters[i] ^= 0b1111111111111 if @frameCheckSequence[i] == 1
    end
    #puts "Characters with FCS:".ljust(LabelWidth, " ") + @characters.map{|character| character.to_hex(4) }.join(" ").rjust(65, " ")
    
    # Map to bars
    @barcode = Mapping.collect do |map|
      @characters[map[0][0]][map[0][1]] + 2 * @characters[map[1][0]][map[1][1]]
    end
    # While it's still an array, put it to good use by `puts`ing it
    #puts "Barcode Letters:".ljust(LabelWidth, " ") + @barcode.map{|bar| "TDAF"[bar] }.join.rjust(65, " ")
  end
  
  CRCPolynomial = 0x0F35
    
  def crc 
    frameCheckSequence = 0x07FF
    bytes = @binaryData.bytes(13).reverse
    data = bytes[0] << 5
    6.times do |i|
      usePolynomial = (frameCheckSequence ^ data) & 0x400
      frameCheckSequence <<= 1
      frameCheckSequence ^= CRCPolynomial if usePolynomial != 0
      frameCheckSequence &= 0x7FF # make sure frameCheckSequence still only consumes 11 bits
      data <<= 1
    end
    
    # other bytes
    for byte in bytes[1...13]
      data = byte << 3
      8.times do
        usePolynomial = (frameCheckSequence ^ data) & 0x400
        frameCheckSequence <<= 1 
        frameCheckSequence ^= CRCPolynomial if usePolynomial != 0
        frameCheckSequence &= 0x7FF # make sure frameCheckSequence still only consumes 11 bits
        data <<= 1
      end
    end
    #puts "FrameCheckSequence = 0b#{frameCheckSequence.to_bin 11}"
    return frameCheckSequence
  end
end

class Numeric
  def bytes(minBytes=0)
    bytes = Array.new
    i = 1
    while minBytes >= i or 2**(8*(i-1)) <= self
      bytes.push self >> 8*(i-1) & 0xFF
      i += 1
    end
    return bytes
  end

  def to_bin(min_digits = 8)
    result = self.to_s(2).rjust(min_digits, "0")
    return result
  end 

  def to_hex(min_digits = 2)
    result = self.to_s(16).rjust(min_digits, "0")
    #puts "0x#{result} (#{result.length} bits) = #{self}"
    return result
  end
  
  def to_quat(min_digits = 4)
    result = self.to_s(4).rjust min_digits, "0"
    #puts "0q#{result} (#{result.length} bits) = #{self}"
    return result
  end
end

class String
  def group(groupSize, seperator)
    remainder = self.length % groupSize
    result = []
    result = result << self[0, remainder] if remainder > 0
    (self.length / groupSize).times do |group|
      result = result << self[(remainder + group * groupSize), groupSize]
    end
    
    return result.join seperator
  end
end

def test
  bar
end

