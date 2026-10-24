import Foundation
import SwiftData

@Model public final class DatabasePatient {
    @Attribute(.unique) public var patient_id: String
    public var title: String
    public var first_name: String
    public var last_name: String
    public var date_of_birth: String
    public var age: String
    public var gender: String
    public var address_line1: String
    public var suburb: String
    public var state: String
    public var postcode: String
    public var mobile: String
    public var email: String
    public var medicare_number: String
    public var aboriginal_torres_strait_islander: String
    public var preferred_language: String
    public var allergies: String
    public var current_medications: String
    public var medical_conditions: String
    public var smoking_status: String
    public var alcohol_use: String
    public var emergency_contact_name: String
    public var emergency_contact_relationship: String
    public var emergency_contact_phone: String
    public var preferred_gp: String
    public var last_visit_date: String
    public var notes: String
    @Relationship(deleteRule: .cascade, inverse: \DatabaseConsultationNote.patient) public var consultationNotes: [DatabaseConsultationNote] = []
    public static let columns = ["patient_id", "title", "first_name", "last_name", "date_of_birth", "age", "gender", "address_line1", "suburb", "state", "postcode", "mobile", "email", "medicare_number", "aboriginal_torres_strait_islander", "preferred_language", "allergies", "current_medications", "medical_conditions", "smoking_status", "alcohol_use", "emergency_contact_name", "emergency_contact_relationship", "emergency_contact_phone", "preferred_gp", "last_visit_date", "notes"]
    public init(row: [String: String]) {
        self.patient_id = row["patient_id"] ?? ""
        self.title = row["title"] ?? ""
        self.first_name = row["first_name"] ?? ""
        self.last_name = row["last_name"] ?? ""
        self.date_of_birth = row["date_of_birth"] ?? ""
        self.age = row["age"] ?? ""
        self.gender = row["gender"] ?? ""
        self.address_line1 = row["address_line1"] ?? ""
        self.suburb = row["suburb"] ?? ""
        self.state = row["state"] ?? ""
        self.postcode = row["postcode"] ?? ""
        self.mobile = row["mobile"] ?? ""
        self.email = row["email"] ?? ""
        self.medicare_number = row["medicare_number"] ?? ""
        self.aboriginal_torres_strait_islander = row["aboriginal_torres_strait_islander"] ?? ""
        self.preferred_language = row["preferred_language"] ?? ""
        self.allergies = row["allergies"] ?? ""
        self.current_medications = row["current_medications"] ?? ""
        self.medical_conditions = row["medical_conditions"] ?? ""
        self.smoking_status = row["smoking_status"] ?? ""
        self.alcohol_use = row["alcohol_use"] ?? ""
        self.emergency_contact_name = row["emergency_contact_name"] ?? ""
        self.emergency_contact_relationship = row["emergency_contact_relationship"] ?? ""
        self.emergency_contact_phone = row["emergency_contact_phone"] ?? ""
        self.preferred_gp = row["preferred_gp"] ?? ""
        self.last_visit_date = row["last_visit_date"] ?? ""
        self.notes = row["notes"] ?? ""
    }
    public func update(row: [String: String]) {
        self.patient_id = row["patient_id"] ?? ""
        self.title = row["title"] ?? ""
        self.first_name = row["first_name"] ?? ""
        self.last_name = row["last_name"] ?? ""
        self.date_of_birth = row["date_of_birth"] ?? ""
        self.age = row["age"] ?? ""
        self.gender = row["gender"] ?? ""
        self.address_line1 = row["address_line1"] ?? ""
        self.suburb = row["suburb"] ?? ""
        self.state = row["state"] ?? ""
        self.postcode = row["postcode"] ?? ""
        self.mobile = row["mobile"] ?? ""
        self.email = row["email"] ?? ""
        self.medicare_number = row["medicare_number"] ?? ""
        self.aboriginal_torres_strait_islander = row["aboriginal_torres_strait_islander"] ?? ""
        self.preferred_language = row["preferred_language"] ?? ""
        self.allergies = row["allergies"] ?? ""
        self.current_medications = row["current_medications"] ?? ""
        self.medical_conditions = row["medical_conditions"] ?? ""
        self.smoking_status = row["smoking_status"] ?? ""
        self.alcohol_use = row["alcohol_use"] ?? ""
        self.emergency_contact_name = row["emergency_contact_name"] ?? ""
        self.emergency_contact_relationship = row["emergency_contact_relationship"] ?? ""
        self.emergency_contact_phone = row["emergency_contact_phone"] ?? ""
        self.preferred_gp = row["preferred_gp"] ?? ""
        self.last_visit_date = row["last_visit_date"] ?? ""
        self.notes = row["notes"] ?? ""
    }
    public var jsonObject: [String: Any] {
        [
            "patient_id": patient_id,
            "title": title,
            "first_name": first_name,
            "last_name": last_name,
            "date_of_birth": date_of_birth,
            "age": age,
            "gender": gender,
            "address_line1": address_line1,
            "suburb": suburb,
            "state": state,
            "postcode": postcode,
            "mobile": mobile,
            "email": email,
            "medicare_number": medicare_number,
            "aboriginal_torres_strait_islander": aboriginal_torres_strait_islander,
            "preferred_language": preferred_language,
            "allergies": allergies,
            "current_medications": current_medications,
            "medical_conditions": medical_conditions,
            "smoking_status": smoking_status,
            "alcohol_use": alcohol_use,
            "emergency_contact_name": emergency_contact_name,
            "emergency_contact_relationship": emergency_contact_relationship,
            "emergency_contact_phone": emergency_contact_phone,
            "preferred_gp": preferred_gp,
            "last_visit_date": last_visit_date,
            "notes": notes
        ]
    }
    public func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = MedicareID.normalise(term)
        return term.isEmpty || first_name.localizedCaseInsensitiveContains(term)
            || last_name.localizedCaseInsensitiveContains(term)
            || (!id.isEmpty && MedicareID.normalise(medicare_number).contains(id))
    }
    /// Why a manual consult can't be started for this record, or nil when it can.
    public var consultBlockReason: String? {
        if MedicareID.normalise(medicare_number).isEmpty { return "No Medicare number on this record." }
        if !IdentityValidation.validDOB(date_of_birth) { return "Date of birth isn't a valid date (yyyy-MM-dd)." }
        return nil
    }
    public func serializedJSON() throws -> String {
        var object = jsonObject
        object["consultation_notes"] = consultationNotes.sorted {
            $0.visit_date == $1.visit_date ? $0.note_id < $1.note_id : $0.visit_date > $1.visit_date
        }.map(\.jsonObject)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        return String(decoding: data, as: UTF8.self)
    }
}

@Model public final class DatabaseConsultationNote {
    @Attribute(.unique) public var note_id: String
    public var patient_id: String
    public var visit_date: String
    public var visit_type: String
    public var clinician: String
    public var reason: String
    public var history: String
    public var examination: String
    public var assessment: String
    public var plan: String
    public var actions: String
    public var recorded_context: String
    public var patient: DatabasePatient?
    public static let columns = ["note_id", "patient_id", "visit_date", "visit_type", "clinician", "reason", "history", "examination", "assessment", "plan", "actions", "recorded_context"]
    public init(row: [String: String]) {
        self.note_id = row["note_id"] ?? ""
        self.patient_id = row["patient_id"] ?? ""
        self.visit_date = row["visit_date"] ?? ""
        self.visit_type = row["visit_type"] ?? ""
        self.clinician = row["clinician"] ?? ""
        self.reason = row["reason"] ?? ""
        self.history = row["history"] ?? ""
        self.examination = row["examination"] ?? ""
        self.assessment = row["assessment"] ?? ""
        self.plan = row["plan"] ?? ""
        self.actions = row["actions"] ?? ""
        self.recorded_context = row["recorded_context"] ?? ""
    }
    public func update(row: [String: String]) {
        self.note_id = row["note_id"] ?? ""
        self.patient_id = row["patient_id"] ?? ""
        self.visit_date = row["visit_date"] ?? ""
        self.visit_type = row["visit_type"] ?? ""
        self.clinician = row["clinician"] ?? ""
        self.reason = row["reason"] ?? ""
        self.history = row["history"] ?? ""
        self.examination = row["examination"] ?? ""
        self.assessment = row["assessment"] ?? ""
        self.plan = row["plan"] ?? ""
        self.actions = row["actions"] ?? ""
        self.recorded_context = row["recorded_context"] ?? ""
    }
    public var jsonObject: [String: Any] {
        [
            "note_id": note_id,
            "patient_id": patient_id,
            "visit_date": visit_date,
            "visit_type": visit_type,
            "clinician": clinician,
            "reason": reason,
            "history": history,
            "examination": examination,
            "assessment": assessment,
            "plan": plan,
            "actions": actions,
            "recorded_context": recorded_context
        ]
    }
}

